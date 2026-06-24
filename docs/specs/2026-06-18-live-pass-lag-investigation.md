# Live-Pass Speaker Collapse & Lag — Investigation + Instrumentation

**Date:** 2026-06-18 (updated 2026-06-19)
**Status:** Root cause **identified and reproduced.** D42 (in-process gate reclaim)
stops a *single transient* wedge from permanently freezing diarization — but a live run
on 2026-06-19 showed it is **not sufficient under a wedge storm**: the reclaim relaunches
into a still-jammed ANE, the un-cancellable hung calls pile up, and they end up starving
Parakeet **transcription** too (see §0b). The real fix is **process isolation (D43)** —
run the diarizer in its own killable worker so `SIGKILL` releases the wedged ANE call;
plan in `docs/specs/2026-06-19-diarizer-worker-process-plan.md`.

> **RESOLVED 2026-06-19.** D43 shipped, and a live replay confirmed it saved
> **transcription** — but also revealed the *real* root cause: the "wedge" was
> never ANE contention. It was FluidAudio's verbose logging **blocking in
> `write()` on a full, slowly-drained stderr pipe.** The ANE-contention narrative
> in §0/§0b/§0c is a **misdiagnosis**; the corrected mechanism, the `lldb`/
> `spindump` evidence, and the actual fixes are in **§10**.
**Branches:** D42 instrumentation + reclaim on `fix/live-diarizer-wedge-reclaim`
(off the ANE branch `feat/ane-transcription-pipeline`).

---

## 0. Resolution (D42) — what it actually was

The reference recording `2026-06-18-212738` (a playback of `2026-06-15-094728`,
captured with the tracing) caught it. The trace showed: live diarization ran cleanly
for ~95 s, then emitted `live trace diar SKIPPED(gate busy)` **continuously for the
remaining ~170 s** — every window after the first wedge was skipped. So:

1. **Trigger (upstream, FluidAudio).** One `diarizeWindow` call hangs and never
   returns. The hang is in `OfflineEmbeddingExtractor.runEmbeddingModel`, the one place
   in FluidAudio's offline diarizer that still uses the **synchronous** `MLModel.prediction`
   (every other call is `await`-async). FluidAudio's own prewarm comment documents that
   this synchronous ANE prediction "can hang indefinitely when the ANE is contended …
   no way to specify a timeout," and being synchronous it is **deaf to `Task` cancellation**.
   FluidAudio is pinned at `exact: 0.15.2`, so this is not our code to edit in-tree.

2. **Why our timeout couldn't save it.** `LiveDiarizer.diarizeWindow`'s 30 s
   `withTaskGroup` timeout fires, but `withTaskGroup` does not return until **all** child
   tasks finish — and the child awaiting the un-cancellable hung work never finishes. So
   `diarizeWindow` never returns, the `DiarGate` slot is never released, and live
   diarization is dead for the rest of the recording → every later utterance falls back to
   `?? "Them"` → the system stream "sticks to one speaker."

3. **Reproduced deterministically.** `LiveRunnerResilienceTests` now injects a
   `WedgingDiarizer` whose first window wedges **deaf to cancellation** (parks on a
   continuation), proving the freeze without any ANE — and proving the recovery after the
   fix.

4. **Fix (ours, D42 — resilience).** `DiarGate` now **reclaims a slot held past a
   deadline** (default **2 s**, ~10× a healthy ~0.2 s window) *without awaiting the wedged
   work*, using a **generation token** so the abandoned window's late `release()` can't
   free a newer holder's slot. A reclaim logs `live trace diar RECLAIMED wedged slot`.
   One wedged window now costs ~one window (~5 s), not the whole call.

**Still open after D42:** the reclaim makes a *single* freeze non-fatal, but each wedged
window is still *lost* and the hung FluidAudio call still leaks (in-process, it cannot be
released). §0b shows why that leak is worse than it sounds, and §0c is the chosen fix.

---

## 0b. Live-run verification (2026-06-19) — D42 is not enough; it amplifies a storm

Replayed the original problem recording `2026-06-18-084407` (~7 min) through a live
session built **with D42** (gate reclaim) + the per-pass tracing, on an otherwise idle
M2 (pure playback — no real meeting load). Log `2026-06-19.log`, ~03:01–03:07Z. This run
caught a far worse failure than the single freeze, and it implicates D42 itself.

**Timeline (audio-relative `t`):**

| `t` | Diarizer | Transcription / queues |
|---|---|---|
| 25→105 s | healthy; `keys` 1→2→3, `stateSpans`→25 | committing; `qSys=qMic=0` |
| **~110 s** | first wedge → `RECLAIMED`, **then `RECLAIMED` every 5 s to the end** | still committing |
| ~152 s | reclaim cascade | **last commit (161 tokens), then no more transcriber lines** |
| ~134→164 s | cascade | decode queues fill `qSys/qMic 0 → 249 → … → 1500` over ~30 s |
| 164 s → end | cascade | `qSys=qMic=1500` (full, dropping) → "recording paused" in `live.md` |

**The causal chain (this is the key new finding):**

1. One diar window wedges at `t≈110 s` (the synchronous FluidAudio embedding `prediction`
   hangs — §0).
2. D42 reclaims the slot and **launches a new window every 5 s**. But the ANE is still
   jammed by the *previous* hung call, so **each new window also wedges.** The reclaim
   cannot cancel or release the prior call (it is un-cancellable in-process) — it only
   abandons it. So the leaked, hung ANE calls **accumulate, one every 5 s.**
3. For the first ~6 wedges (~30 s) the queues stay at 0 — transcription is unaffected.
   Then, once ~6–7 leaked diar calls are pinning the ANE, **Parakeet decodes can no longer
   get ANE time**: the decode worker stalls, its bounded queues fill `0→1500` over 30 s,
   and audio is dropped → "recording paused." Transcription is dead for the rest of the run.

This dose-response (transcription survives the first ~6 wedges, dies once ~7 leaks
accumulate) is strong evidence the diar leaks **starve Parakeet** — the transcription
stall is *not* an independent bug; it is a downstream consequence of the diar cascade.

**The uncomfortable conclusion:** D42 made the *storm* case worse for the live experience.
- **Before D42** (run `2026-06-18-212738`): one wedge → diarization froze, but **transcription survived** the whole call.
- **With D42** (this run): the reclaim keeps relaunching → leaks pile up → **both diarization and transcription die.**

So in-process reclaim is the wrong layer: it trades a single permanent diar-freeze for an
unbounded leak that eventually takes transcription down too. The root issue is unchanged —
**an un-cancellable synchronous ANE call can only be released by killing the process that
holds it.** (The WAV is always whole, so the offline refine pass still recovers the full
transcript + diarization; only the *live* view degrades.)

---

## 0c. Chosen fix (D43) — process isolation

Run the live diarizer in its own **killable worker process**, fed audio over a Unix-domain
socket, returning raw spans+embeddings to the engine; the engine supervises it with a
per-window deadline and `SIGKILL`s + respawns it on a hang. Process death is the one
primitive that actually releases a wedged ANE call (the kernel tears down the dead client's
ANE driver session), so a hang becomes a recoverable ~1 s blip instead of a permanent leak,
and it can never starve Parakeet (different process). The cross-window stitcher stays
engine-side, so a respawned worker loses no `Them #N` identity continuity.

Decisions: **diarizer-only** (transcriber stays in the engine); **supervisor + socket IPC**;
**no** cross-process ANE coordination. Full task-by-task plan:
`docs/specs/2026-06-19-diarizer-worker-process-plan.md`.

---

## 1. Reported symptom

In the **live** transcript the system-stream diarizer "sticks to one speaker" — it
does not track speaker switches and glues long stretches onto a single name. The
**refined** (offline) transcript on the same recording separates speakers correctly.

Reference recording: `2026-06-18-084407` (`~/.../meetings/pulsartrace/`), a ~7 min
4-speaker call (mic = "You"; system = Stanisław, Kacper, Mateusz — all Revoize).

### Live vs refined, concretely
- **Refined** `final.md`: Mateusz's monologue `04:52–06:28` correctly attributed to
  **Mateusz (Revoize)**; clean switches throughout.
- **Live** `.live.md.bak`: that whole monologue is labelled **"Stanisław (Revoize)?"**,
  and from ~`02:00` on almost everything collapses to "Stanisław". A spurious
  **"Jarich?"** (not in the meeting) appears at `01:57`.

---

## 2. What we measured

All numbers below are measured this session (throwaway diagnostics, since removed).

### 2a. The diarizer is **not** the problem
Replaying the live windowed pass (`engine.diarize(samples:)` per 10 s window / 5 s
step) over the recording's `audio-system.wav`, with the production stitch:

- **The embedding space separates the speakers cleanly.** Refine per-speaker
  cross-cosines: `Stanisław~Kacper 0.279`, `Stanisław~Mateusz 0.280`,
  `Kacper~Mateusz 0.159` (same-speaker ~0.93). Highly separable.
- **The live stitch forms the right keys**, including a **correct Mateusz key**
  (`Them #5`, 22 windows over exactly `04:50–07:00` → Mateusz @ 0.90), plus
  `Them` → Stanisław 0.91 and `Them #3` → Kacper 0.92.
- **The stitch threshold is a non-lever.** Key structure is *identical* from
  threshold 0.40 → 0.55 (5 keys). (Note: it *was* changed 0.55 → 0.45 in the ANE
  migration, but that change does not affect this recording's separation.)
- There **is** a real but secondary over-split: a phantom `Them #2` (stable across
  16 windows, self-cosine 0.87–0.94) that mis-resolves to a non-attendee "Jarich"
  @ 0.95. Threshold-independent.

**Conclusion:** the diarizer + stitch produce a correct Mateusz key over the exact
window the live transcript mislabels as Stanisław. The collapse is **downstream of
diarization.**

### 2b. The downstream label mechanism
`LiveRunner.resolveSystemLabel` (Streaming/LiveRunner.swift) does:

```swift
let key = await diarState.dominantKey(start: utterance.start, end: utterance.end) ?? "Them"
// → SpeakerLibrary.bestMatch(centroids()[key]) → "<name>?"
```

`LiveDiarizer.provisionalKey(index: 0)` is **literally the string `"Them"`**. So when
`dominantKey` finds **no diar span** overlapping an utterance and falls back to
`?? "Them"`, that string **collides with the first real speaker's key** — its centroid
exists, R18 resolves it, and the "unknown" fallback inherits the *first speaker's name*
(here Stanisław). i.e. an utterance with no live-diar coverage is silently labelled the
first speaker.

### 2c. What the **real recording's** log already shows
Mining `~/Library/Logs/PulsarTrace/2026-06-18.log` against every failure the code can
report today:

| Signal | Count in the real run |
|---|---|
| `advancing anchor to catch up` (transcriber anchor > 2 windows behind wall-clock) | **29** |
| `falling behind; dropping … audio` (bounded-queue overflow) | **0** |
| `decode failed` / `exceeded deadline` | **0** |
| `LiveRunner phase=…` (a stuck `await` ≥ 2 s) | **0** |

So the only thing that went wrong was the **transcriber's commit anchor falling
>20 s behind wall-clock**, repeatedly (starting ~1 min in, 12:45:03 → 12:51:15Z, the
whole session). No queue drops, no decode failures, no wedged awaits.

### 2d. Idle-machine replay keeps up perfectly
Driving the **real** pipeline (`StreamingPipeline` + `LiveRunner` + one shared
`ParakeetEngine` actor + real `DiarizerEngine` + real library) over a wall-clock-paced
playback of the same audio, fed by a **dedicated OS thread** (immune to the cooperative
pool, like the real socket):

```
runWall 360.3s for 360s audio · dropsSys=0 dropsMic=0 · diarRan=71 diarSkip=0
medianLag 6.8s · maxLag 11.5s · 57 live lines
per-frame: offloadCheap 0.04ms (×35.8k) · offloadDecode 142ms (×149) · loopBody 0.4ms
```

On an idle machine the pipeline **keeps up exactly at real-time**, drops nothing, skips
no diar window, and lags only ~6.8 s (inherent window + LocalAgreement-2 + diar
latency). The consumer is ~7 % busy.

### 2e. The fixture confound (why an earlier number was wrong)
An earlier replay with `FixturePlaybackSource(realtime:)` reported a 38 s median lag.
That source paces with `Task.sleep(20ms)` **on the same cooperative pool** as the
148 ms decodes, so the timers fire late and the *feed itself stretches* (449 s wall for
360 s audio). That number is an **artifact of the test harness, not the app** — the real
capture daemon feeds the socket at true wall-clock regardless of engine load. The
thread-fed run (2d) replaced it and is the trustworthy figure.

---

## 3. Ruled out — do **not** re-chase these

- **Clustering / AHC threshold / stitch threshold tuning.** The whole premise of the
  `fix/live-diarizer-over-split` branch (raise AHC `clustering.threshold` 0.6 → 1.05).
  Speakers are already highly separable; the threshold sweep is a non-lever; the AHC
  change was correctly reverted (it aggravates *under*-split, the opposite of "over").
- **Per-segment `chunkEmbeddings` stitch** (an earlier abandoned approach / PR #11) —
  those are pre-clustering noisy inputs; re-implementing clustering badly.
- **Per-frame plumbing overhead** (`LiveRunner.offload`) — measured at **0.04 ms**/frame
  (1.4 s total over 35.8k frames). Negligible.
- **Inherent throughput / "the pipeline is too slow"** — idle machine keeps up at
  real-time with ~7 % busy and large ANE headroom (`<10 %` duty).
- **Queue drops, decode failures/timeouts, wedged `await`s** — all **0** in the real
  run's log.

---

## 4. Still unknown (the actual gap)

**Why did the real run's commit anchor fall >20 s behind wall-clock, while the
identical audio + code on an idle machine keeps up?** The idle replay also **bypassed
several real components**, any of which could harbour an accumulating bug — this is not
proven to be "system load":

- the **capture daemon** (separate process: ScreenCaptureKit + mic);
- the **socket/IPC path** (`SocketSource` + `FrameDescriptorReader`) — replay fed frames
  from a thread, not the wire;
- the **events writer** (`events: lifecycle.events`) — replay passed `nil`;
- the **menu-bar parent process** + its live.md watcher.

Open candidates for the anchor lag (all currently un-instrumented at production level):
1. decodes that **succeed but run slower** on the real machine (142 ms idle → ?);
2. **LocalAgreement-2 committing sparsely** (the anchor only advances on commits; if
   consecutive windows disagree it stalls while wall-clock runs on);
3. a steady **worker backlog under 30 s** (lags but never drops);
4. **diar skips** — completely uninstrumented in the existing log, so we cannot even
   confirm whether the speaker-collapse came from diar starvation.

It is also not yet established whether the **transcription anchor lag** (§2c) and the
**diarization speaker-collapse** (the reported symptom) share one cause or are two
load-driven effects.

---

## 5. Instrumentation introduced

Per-pass tracing at `.notice` (visible in the production op log; numbers/labels only —
no paths, transcript text, or speaker names, per the log-hygiene invariant). One line
per pass; passes fire every ~4 s (transcriber) / ~5 s (diar).

**Files changed:**
- `Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift` — per-decode latency,
  VAD-skip flag, `streamLabel`, and the transcriber trace line in `drainWindows`.
- `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift` — `streamLabel` wiring; the diar
  trace (launch-lag, latency, spans, buffer/state/keys, queue depths) + the skip line.
- `Sources/PulsarTraceEngine/Streaming/DiarState.swift` — `count()` accessor.
- `Sources/PulsarTraceEngine/Streaming/BoundedFrameQueue.swift` — `depth` accessor.

**Transcriber pass (per stream):**
```
live trace transcriber[system|mic]: anchor=<s>s total=<s>s lag=<s>s buf=<s>s
  decode=<ms>ms vad=<bool> committedTokens=<n>
```
- `anchor` — audio position of the commit point (end of last committed audio)
- `total` — total audio received
- `lag` = wall − anchor — **how far behind live is** (the §2c quantity, as a value)
- `buf` — rolling decode buffer depth
- `decode` — decode latency (0 if VAD-skipped)
- `vad` — was this window silence-skipped
- `committedTokens` — cumulative committed tokens (growing vs stalled)

**Diar pass:**
```
live trace diar: t=<s>s launchLag=<s>s ran=<ms>ms spans=<n> diarBuf=<s>s
  stateSpans=<n> keys=<n> qSys=<n> qMic=<n>
live trace diar SKIPPED(gate busy): t≈<s>s diarBuf=<s>s qSys=<n> qMic=<n>
```
- `t` — audio position of the diar window · `launchLag` = wall − t
- `ran` — diar latency · `spans` — produced this window
- `diarBuf` — diar buffer depth · `stateSpans` — total accumulated spans
- `keys` — # provisional speaker keys formed (**the collapse signal**)
- `qSys`/`qMic` — bounded-queue backlog (frames waiting for the decode worker)

Verified: emits with sane values on a 30 s smoke run; **Streaming 19/19** and
**UnitTests 376/376** green (the new init param defaults to `streamLabel: "?"`).

---

## 6. How to capture a real run

1. Run the **debug/dev app that launches `.build/debug/pulsartrace-engine`** (already
   rebuilt with the tracing). A pre-built release `.app` will **not** include it.
2. Record a real call where the collapse reproduces.
3. Read the trace:
   ```
   grep "live trace" ~/Library/Logs/PulsarTrace/<YYYY-MM-DD>.log
   ```

---

## 7. How to read the trace → which hypothesis

| Pattern over the session | Points at |
|---|---|
| `lag` ↑ **and** `qSys`/`qMic` ↑ | worker backlog — decode can't drain the queue |
| `decode` ms ↑ over time | decodes themselves slow (CPU/ANE contention, thermal) |
| `lag` ↑ but `qSys`=0 and `decode` flat | feed/scheduling, not compute (anchor stalling) |
| `committedTokens` stalls while `total` grows | LocalAgreement-2 committing sparsely |
| `SKIPPED` lines appear | diarizer starvation (gate busy) |
| `keys` stuck low when speakers switch | collapse at the diarizer, not just the label |

---

## 8. Next steps

1. **Capture + analyse a real recording** with the tracing (§6/§7). This is the
   deliverable that turns "unknown" into a pinpointed cause. Until then, do not assume
   load vs bug.
2. ~~**Ship the label-fallback fix regardless of root cause (cheap, certain).**~~
   **DONE (2026-06-19).** A no-coverage utterance no longer inherits the first
   speaker's name: the `?? "Them"` fallback now resolves to the neutral `Speaker?`
   marker and skips the R18 name lookup. See the §10 "label collapse" follow-up.
3. **Target the measured cause** once §1 identifies it — e.g. if it's decode contention,
   the shared `ParakeetEngine` actor serializing mic+system through a semaphore bridge is
   the first lever; if it's diar skips, make coverage resilient to a missed window.
4. **Optional controlled reproduction:** stand up the real two-process socket path (a
   wall-clock-paced writer → real `SocketSource`) in a test to check whether the IPC path
   itself accumulates lag that the thread feed did not.
5. **Branch + commit** the instrumentation off the ANE branch; downgrade the trace to
   `.debug` or remove it once the cause is found.

---

## Appendix — key code references (as of 2026-06-18)

- Label fallback + R18: `Streaming/LiveRunner.swift` `resolveSystemLabel(...)`
- `"Them"` == first provisional key: `Streaming/LiveDiarizer.swift` `provisionalKey(index:)`
- Transcriber anchor / backpressure: `Streaming/StreamingTranscriber.swift` `drainWindows` / `runWindow`
- Diar cadence + single-in-flight skip: `Streaming/DiarBufferManager.swift`, `Streaming/DiarGate.swift`
- Hand-off queue drop-oldest: `Streaming/BoundedFrameQueue.swift`
- Window geometry: transcriber 10 s window / 4 s step; diar 10 s window / 5 s step

---

## 9. D43 implementation status (2026-06-19)

The worker-process plan (`docs/specs/2026-06-19-diarizer-worker-process-plan.md`)
is **implemented and merged on `fix/live-diarizer-wedge-reclaim`** (12 commits,
`0d3b540`…`d28f760`). Live windowed diarization now runs in a separate killable
worker process; a hung ANE prediction is recovered by `SIGKILL` + respawn rather
than leaking in-process and starving Parakeet.

**What landed (engine target unless noted):**

- `Diarization/DiarWindowResult.swift` — `Codable` wire DTO (spans + embeddings,
  ms ints) + `DiarWorkerMessage` envelope (`hello`/`result`).
- `Diarization/DiarWorkerProtocol.swift` — 4-byte LE length-prefixed frame codec
  (binary request, JSON message); scalar reads use `loadUnaligned`.
- `Diarization/RawWindowDiarizing.swift` — the narrow seam `LiveDiarizer` now
  drives; `Diarization/DiarizerEngineRawAdapter.swift` adapts the in-process
  `DiarizerEngine` to it (used inside the worker + the offline E2E test).
- `Diarization/DiarWorkerConnection.swift` — bidirectional frame transport over a
  connected fd (blocking-read thread → `AsyncStream<Data>`).
- `Diarization/DiarWorkerServer.swift` — the stateless worker run loop.
- `Diarization/DiarWorkerClient.swift` — the supervisor actor: per-window
  deadline via a `CheckedContinuation` keyed by `requestId` (resumed by whichever
  of the reader / deadline wins — **no task-group await**, so a hung reply cannot
  re-wedge the engine), `SIGKILL` + capped-exponential-backoff respawn.
- `Diarization/DiarWorkerProcessLauncher.swift` — engine is the socket server
  (bind/listen once, accept + read `hello` per incarnation); spawns
  `pulsartrace-engine --diarizer-worker`; the `@Sendable` kill closure captures
  only the child pid and guards `pid > 0` (never `kill(-1)`).
- `Streaming/LiveDiarizer.swift` — stitches over `RawWindowDiarizing`; in-process
  engine + `withTaskGroup` window timeout removed (the supervisor owns timeouts).
- `Streaming/StreamingPipeline.swift` — `Configuration.liveRawDiarizer` replaces
  `liveDiarizerEngine`. `pulsartrace-engine/main.swift` — `--diarizer-worker`
  mode + `live()` spawns a `DiarWorkerClient`, honouring `--no-live-diarization`
  and reusing the existing `recordingId` for the socket path.

Cross-window stitch state (`liveSpeakers` centroids, `Them #N` keys) stays
engine-side, so a respawned worker loses no identity continuity. The D42 in-process
`DiarGate` reclaim is left in place as a harmless ≤1-window-in-flight backstop.

**Automated verification — green at `d28f760`:** `swift build` clean;
`--filter DiarWorker` 11/11 (the real-worker integration test is gated on
`PT_DIAR_WORKER_E2E=1` + models present, skipped by default); `--filter UnitTests`
387/387; `--filter LiveRunner` 17 (one pre-existing flaky heartbeat test gated);
`--filter Streaming` 19/19. The `DiarWorkerClient` `hangThenRecover` test is the
process-level analogue of the D42 recovery test (hung worker → deadline → kill →
next window recovers), deterministic across repeated runs.

**Manual live verification — DONE (2026-06-19).** Ran the replay (dev app →
`.build/debug/pulsartrace-engine`, the `2026-06-18-084407` system audio). Result:
D43 kept **transcription** healthy the whole run (`qSys=qMic=0`, no "recording
paused") — a clear win over the D42 run, which cascaded to `qSys=qMic=1500` and
killed transcription. **But diarization still died** after the first wedge
(`ran=0ms spans=0` to the end → every later utterance mislabelled as the first
speaker, the reported symptom). Chasing *why the respawn never recovered*
uncovered the real root cause — and it was **not** the ANE. See **§10**.

---

## 10. Resolution (2026-06-19) — the real root cause: a blocking stderr pipe, not the ANE

The §9 replay forced the issue. D43 did what it was designed to do —
**transcription survived** — but live diarization went dark after the first wedge
and never came back, so the "everything becomes Stanisław" symptom persisted.
Capturing the stuck worker mid-failure overturned the entire ANE-contention theory.

### What the replay showed (run 16:49–16:53Z, the D43 build)

- Healthy for ~105 s: `live trace diar: ran≈200ms spans=1–3`, `keys` 1→2→3.
- At audio t≈110 s one window exceeded the 2 s deadline → `diar worker: window
  deadline exceeded — killing + respawning`. ✓ D43 detected it and killed the worker.
- From t=120 s to the end: **`ran=0ms spans=0` every window** — the supervisor's
  `handle` stayed nil because the respawned worker never finished loading.
- The respawned worker's `diarizer: models resident` is timestamped **16:53:07.869**,
  ~90 ms *after* `live pass finished` (16:53:07.780). It made **zero** progress for
  ~106 s and completed only as the stream stopped. So "106 s to reload" was the
  wrong framing: it was **blocked the whole time and unblocked at teardown.**
- Throughout, `qSys=qMic=0` and the transcriber kept committing — transcription fine.

### The capture (`lldb` + `spindump` of the stuck worker, pid 60957)

Both tools agree. The model-load task spent **397/397 samples** (the full 5 s) here:

```
diarizerWorker → DiarizerEngine.load → prepareModels → prewarmModelsIfNeeded
  → prewarmEmbeddingStack → extractEmbeddings → emitProfileLog
    → NSFileHandle.write → write          ← blocked in the syscall
```

- `CPU Time: <0.001s` over the 5 s — doing nothing. Pure I/O block.
- That thread "last ran 85 s ago" — parked in `write()` for 85 s.
- `ANEServicesThread` is idle in its runloop. **The ANE is not busy.**
- The line it was trying to emit: `Embedding timings: … embeddingTotal=6.45ms` —
  the ANE embedding **already finished, in 6 ms.** It was wedged *logging that the
  ANE succeeded.*

`write()` parking for 85 s with zero CPU can only be a pipe/terminal with a full
buffer and no reader draining — not a regular file, and not the ANE.

### The mechanism

1. FluidAudio logs verbosely to **stderr** — `Shared/AppLogger.swift` mirrors
   **every** level to `FileHandle.standardError` in **DEBUG builds**
   (`#if DEBUG → logToConsole`), and `OfflineEmbeddingExtractor.emitProfileLog`
   writes a `[Profiling]` line straight to stderr **per embedding extraction**
   (unconditionally). The offline diarizer hits both, every window.
2. The diarizer worker **inherited the engine's stderr** —
   `DiarWorkerProcessLauncher` never set `standardOutput`/`standardError`.
3. That engine pipe was drained **byte-by-byte** by `RecordOrchestrator` via
   `for try await byte in handle.bytes`, on the cooperative pool in the app
   process. Under the DEBUG flood the drain can't keep up.
4. The 64 KB pipe fills → the next `write()` blocks indefinitely → the worker's
   model load (and, by the same path, a normal serving window) parks in `write()`.
   It "recovers" only when teardown closes the pipe.

This is the **same** `extractEmbeddings → emitProfileLog → write` path that runs on
every serving window, so the **original per-window wedges — and the D42
SKIPPED/RECLAIMED cascades — were almost certainly this too**, not an
un-cancellable ANE prediction. §0/§0b/§0c attributed the hang to FluidAudio's
synchronous embedding `prediction` (citing its prewarm "can hang on a contended
ANE" comment); that was plausible but wrong — the hang is *after* the prediction,
in the profile-log write. The ~4 % ANE duty cycle never fit the "ANE saturated"
story; the blocking-`write()` explanation does.

### The fixes (committed)

- **Worker (`912208e`):** `DiarWorkerProcessLauncher` now sets
  `process.standardOutput = .nullDevice` / `process.standardError = .nullDevice`.
  The worker's real channel is the socket; its stderr was pure FluidAudio noise
  that the engine already discarded (`drainToVoid`), so `/dev/null` is the same
  destination minus the pipe that can block — robust regardless of log volume or
  build config (`/dev/null` never blocks).
- **Engine (`80faa21`):** `RecordOrchestrator` now drains subprocess pipes with a
  chunked, blocking `readToEnd()` on a background thread instead of byte-by-byte
  `FileHandle.bytes` on the cooperative pool — so a chatty child (the engine's own
  Parakeet FluidAudio logging in debug) can't outpace the reader and fill the pipe.

### Result

Re-replayed the same audio: **live diarization now runs cleanly through the whole
call** — no `ran=0ms spans=0` dead zone, no respawn stall, speakers tracked
end-to-end; transcription remains healthy. Confirmed by the user. Automated suites
green (`swift build`; `--filter DiarWorker` 12/12, `RecordOrchestrator` 8/8,
`UnitTests`, `LiveRunner`, `Streaming`).

### Implication for D42 / D43

Both were engineered against a misdiagnosed cause (an un-cancellable ANE hang).
They are not harmful — D43's process isolation is still a reasonable safety net and
the D42 `DiarGate` reclaim is a harmless ≤1-window bound — but the
**kill-respawn-to-release-a-wedged-ANE-call rationale no longer holds**: the actual
wedge was blocking stderr, now fixed at the source. A future cleanup could
reasonably simplify or unwind the worker/kill/respawn machinery now that the live
diarizer no longer wedges. Not done here.

### Follow-up (IMPLEMENTED 2026-06-19) — the label collapse (§2b)

Independent of the wedge: when the live diarizer had **no coverage** for an
utterance, `LiveRunner.resolveSystemLabel` fell back to `?? "Them"`, and `"Them"`
is literally the **first speaker's provisional key**
(`LiveDiarizer.provisionalKey(index: 0)`). So a no-coverage utterance inherited the
first speaker's name through the R18 library lookup — which is why thin coverage
read as "everything is Stanisław." With diarization now healthy this was rarely
hit, but **any** momentary gap still mislabelled.

**Fix (shipped):** `resolveSystemLabel` now `guard`s on `dominantKey` — when it
returns `nil` (no coverage) it returns the neutral marker `Speaker?`
(`LiveRunner.noCoverageLabel`) and **skips the R18 lookup entirely**, so it can
never collide with `provisionalKey(index: 0)` and never inherit a real speaker's
name. The has-coverage path (including a genuine `"Them"` span) is unchanged.
A side effect, by design: when live diarization is unavailable/disabled, every
system utterance is now `Speaker?` rather than `Them?` — accurate, since nothing
was tracked. Tests: `LiveRunnerLibraryLookupTests` (two no-coverage regressions,
incl. the "does not inherit Dana Lee" reproduction); the no-diarizer
`StreamingPipelineTests` case updated to assert `Speaker?` / not `Them?`.
Docs: `docs/file-format.md` provisional-labels section gained the `Speaker?` bullet.
