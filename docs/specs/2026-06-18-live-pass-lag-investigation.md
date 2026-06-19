# Live-Pass Speaker Collapse & Lag — Investigation + Instrumentation

**Date:** 2026-06-18 (updated 2026-06-19)
**Status:** Root cause **identified and reproduced.** D42 (in-process gate reclaim)
stops a *single transient* wedge from permanently freezing diarization — but a live run
on 2026-06-19 showed it is **not sufficient under a wedge storm**: the reclaim relaunches
into a still-jammed ANE, the un-cancellable hung calls pile up, and they end up starving
Parakeet **transcription** too (see §0b). The real fix is **process isolation (D43)** —
run the diarizer in its own killable worker so `SIGKILL` releases the wedged ANE call;
plan in `docs/specs/2026-06-19-diarizer-worker-process-plan.md`.
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
2. **Ship the label-fallback fix regardless of root cause (cheap, certain).** A
   no-coverage utterance must **not** inherit the first speaker's name — the `?? "Them"`
   fallback must resolve to a neutral/unknown marker, not run through the R18 name lookup.
   This removes the misleading "everything is Stanisław" even while coverage is thin.
   (See §2b; `LiveRunner.resolveSystemLabel`.)
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
