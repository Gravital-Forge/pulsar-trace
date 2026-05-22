# Live Transcription Pipeline Decoupling — Recording Safety + Whisper Hang Recovery

- **Status:** design approved, pre-implementation
- **Date:** 2026-05-22
- **Scope:** `pulsartrace-engine` only (the capture daemon is unchanged)
- **Supersedes the open hypothesis in:** `docs/specs/2026-05-20-refine-perf-and-capture-resilience-plan.md` (the "Out of scope" note that guessed the wedge was a sink/speaker-library SQLite read)

## 1. Problem

Live transcription silently stops several times per week, ~17–21 min into a
recording, and a portion of the **recording** (the WAVs) is lost with it. The
phase-tracker heartbeat instrumentation (added 2026-05-21) caught a wedge cold
on 2026-05-22:

```
13:00:07.398Z warning engine  streaming transcription backpressure: decode lag exceeds two windows; advancing anchor to catch up
~13:00:09     phase enters whisper-ingest-mic on frame 129984 — and never leaves
13:00:12 → 13:07:59  heartbeat fires every 2s, same phase, same frame, age 3.2s → 470s and climbing
```

### Root cause

The engine's live path runs on a **single serial loop** (`LiveRunner.run`).
Per frame it does, in sequence (`LiveRunner.swift:353-361`):

1. `appendToWAV(...)` — the **durable recording**, and
2. `micStreamer.ingest(...)` → `StreamingTranscriber.runWindow` →
   `WhisperTranscriber.transcribeWindow` → a **synchronous `whisper_full` call**, then
3. `await sink.appendMicUtterance(...)` — the live.md write.

A single window decode hung indefinitely. Because the WAV write for *subsequent*
frames sits behind the hung decode on the same loop, WAV appends stopped too, and
every frame that arrived afterward (held only in the engine's in-memory
`AsyncStream` buffer) died unpersisted when the engine was killed. **The recording
loss is a direct consequence of the recording write being downstream of whisper on
one thread.**

The decode was a **single bounded 8 s window** (`no_context = true`, so no
growing-context death) — the signature of a degenerate/repetition decode loop.
The live window path uses argmax `temperature = 0` with **no temperature
fallback** and **`max_tokens = 0` (unlimited)** (`WhisperTranscriber.swift:500-505`),
which removes whisper's own escape from a runaway loop. The audio at the wedge
was Polish (`non-English audio detected (pl)` logged repeatedly up to the wedge).

### The hard constraint: `metalLock`

A **process-wide `NSLock` serializes every `whisper_full` call**
(`WhisperTranscriber.swift:99,513`). It exists because whisper's Metal backend
asserts if two contexts touch the GPU concurrently (DECISIONS.md D8). Therefore:

- Running mic-whisper and system-whisper on **separate threads buys no
  parallelism** — the decodes are mutually exclusive at the C level.
- A **hung decode holds `metalLock`**, so the other stream's decode blocks
  forever at `metalLock.lock()`. **Threading alone does not isolate the hang.**
  The only thing that isolates it is the ability to **abort the stuck decode and
  release the lock** — i.e. a per-window watchdog wired to whisper's
  `abort_callback`.

## 2. Goals / Non-goals

**Goals**

- G1 (must): the **recording (WAVs) is never blocked or truncated by whisper** —
  a wedged or arbitrarily-slow decode cannot cost a single frame of recorded audio.
- G2: bounded memory under sustained whisper lag (no unbounded buffering).
- G3: **live transcription recovers** after a single decode hangs, instead of
  dying for the rest of the session.
- G4: when the live view falls behind, that is **visible** (a note in `live.md`)
  and self-documenting, not silent.

**Non-goals**

- Changing the windowed transcription strategy (anchored window +
  LocalAgreement-2 stays).
- Touching the capture daemon (`pulsartrace-capture`). It kept running through
  the wedge; the fix is engine-side. The capture-side unbounded socket queue is
  a separate, latent issue noted for later.
- `final.md` quality: it is rebuilt by the offline post-pass from the **full**
  WAV, so any frames dropped from the *live* view never affect the final
  transcript. This is what makes G1 + best-effort live acceptable.

## 3. Success criteria

- A blocked/slow whisper stub injected into the engine → the WAVs keep growing
  in lockstep with wall-clock time; recording duration on disk == real elapsed
  time (within one frame).
- Memory stays bounded while whisper is blocked (queue at its cap, not growing).
- A whisper stub that hangs on one window → the watchdog aborts it within the
  deadline, that window is dropped with a `live.md` note, and the **next** window
  transcribes normally.
- No filesystem paths in any new log line or note (Hard Invariant #7).

## 4. Architecture

Split the single loop into a **recording-safe drain** and a **best-effort
whisper worker**, connected by a bounded queue. The drain never calls whisper and
never touches `metalLock`.

```
                 merged AsyncStream (frames + ticks, from the socket pumps)
                                   │
                                   ▼
          ┌─────────────────────────────────────────────┐
          │  DRAIN TASK  (async; never calls whisper)     │   ← recording guarantee
          │  • appendToWAV(mic/system)                    │
          │  • feed diar buffer + dispatch (DiarGate)     │
          │  • silence watchdog ticks → gap notes (sink)  │
          │  • enqueue(frame) into bounded queue          │
          │      → non-blocking; DROP-OLDEST if full      │
          └───────────────┬───────────────────────────────┘
                          │ bounded, per-stream (mic, system)
                          ▼
          ┌─────────────────────────────────────────────┐
          │  WHISPER WORKER  (dedicated thread)           │   ← best-effort live transcript
          │  • dequeue frames, drive Streaming­Transcriber │
          │  • transcribeWindow under an ABORT-WATCHDOG   │
          │  • emit committed utterances → sink (live.md) │
          └─────────────────────────────────────────────┘
                          ▲
                          │ arms/clears per-window deadline
          ┌───────────────┴───────────────┐
          │  WATCHDOG TASK (async timer)   │  flips AbortToken on overrun;
          │  (same shape as the heartbeat) │  wired to whisper_full abort_callback
          └────────────────────────────────┘
```

Why **one** whisper worker, not two: `metalLock` serializes the decodes anyway,
so two workers add no throughput — they only re-introduce the hang-coupling (a
worker blocked inside `metalLock.lock()` can't even observe its own watchdog).
One worker owns both `StreamingTranscriber`s and decodes them in turn; its
watchdog runs as an independent task so it can fire while the worker is blocked
in a synchronous decode.

Why the worker is a **dedicated thread**, not a cooperative `Task`:
`whisper_full` is a multi-second synchronous CPU/GPU call. Running it on the
Swift concurrency cooperative pool starves other tasks (the existing heartbeat
already noted this risk). The worker runs on its own `Thread`/serial
`DispatchQueue`; the bounded queue bridges the async drain (producer) to the
sync worker (consumer).

## 5. Components

### 5.1 `BoundedFrameQueue` (new)
- Per-stream (one for mic, one for system). Lock-protected ring buffer of
  `AudioFrame`s, bounded by **audio duration** (default ~30 s, configurable).
- `enqueue(_:)` — non-blocking. If full, **drop the oldest** frame(s) to admit
  the new one, and increment a dropped-duration counter. Drop-oldest (not
  drop-newest) keeps the live view tracking *now* rather than replaying stale
  audio; the dropped span is recovered by the post-pass.
- `dequeue()` — blocks the worker thread until a frame is available or the queue
  is finished (recording end / cancellation).
- Exposes the dropped-duration counter + a "draining caught up" edge so the
  worker can emit the `live.md` note once per drop episode.
- `AudioFrame.samples` is a copy-on-write `[Float]`; enqueue shares the buffer
  with the WAV write (both read-only) — no deep copy.

### 5.2 Drain task (refactor of the current `LiveRunner` loop)
- Keeps the existing merged-stream consumption, WAV writers + finalize `defer`,
  diar buffer feed + `DiarGate` dispatch, and the Fix-A silence watchdog
  (ticks → gap notes). All of that is fast and whisper-free.
- **Removes** the inline `streamer.ingest(...)` + `await sink.appendUtterance`;
  replaces them with `queue.enqueue(frame)` per stream.
- **WAV-first ordering (required for G1):** `appendToWAV` must be the first
  action for every frame, before *any* `await`. Today the mic-resumed case
  awaits `sink.appendGap(.resumed)` *before* the WAV write
  (`LiveRunner.swift:344-354`); the refactor reorders so the recording write can
  never sit behind a sink await. The drain's only awaits are to the cheap,
  serial `LiveSink` (file append) and they follow the WAV write.
- This task is the G1 guarantee: it can run to completion regardless of whisper
  state.

### 5.3 Whisper worker (new)
- Owns `systemStreamer` and `micStreamer` (moved off the drain).
- Loop: dequeue a frame → route to the matching `StreamingTranscriber.ingest`
  → for each committed utterance, hand to the `LiveSink` actor.
- The `StreamingTranscriber`'s existing internal backpressure (anchor-advance on
  lag) is retained as a second, finer layer beneath the queue.

### 5.4 Abort-watchdog + `AbortToken` (Phase 2)
- `AbortToken`: `final class … @unchecked Sendable` wrapping an atomic `Bool`.
- `WhisperTranscriber.transcribeWindow` gains an optional `abort: AbortToken?`
  parameter. When set, it wires whisper's params:
  ```
  params.abort_callback = { ud in
      guard let ud else { return false }
      return Unmanaged<AbortToken>.fromOpaque(ud).takeUnretainedValue().isCancelled
  }                                            // @convention(c), no captures
  params.abort_callback_user_data = Unmanaged.passUnretained(token).toOpaque()
  ```
  `whisper_full` polls this during compute and returns early when it flips true,
  which releases `metalLock`.
- The worker, before each decode, publishes `(token, startInstant)` to a shared
  slot; a watchdog **task** (async timer, the heartbeat shape) flips
  `token.cancel()` if a decode exceeds the deadline (default ~10 s — far above a
  healthy sub-2 s decode, far below the minutes-long hang). On return the slot is
  cleared. An aborted decode → drop that window + `live.md` note → continue.
- Secondary guard: set `params.max_tokens` to a sane per-segment cap (was 0 =
  unlimited) so a runaway decode is bounded even between abort polls. The cap
  must be validated not to truncate legitimately dense 8 s windows.

### 5.5 Protocol seam for testability (new)
- Introduce `protocol WindowTranscribing: AnyObject { func transcribeWindow(_:windowStart:options:abort:) throws -> TranscriptionResult }`.
- `WhisperTranscriber` conforms; `StreamingTranscriber` depends on the protocol
  rather than the concrete type. Tests inject a stub that can return canned
  results, sleep (slow), block forever (hang), or honor/ignore the `AbortToken`.

## 6. Data flow (three regimes)

- **Healthy:** drain writes WAV + enqueues; worker keeps up; queue near-empty;
  watchdog never fires. Identical live output to today.
- **Lagging (whisper slower than real time, not hung):** queue fills to its cap;
  drop-oldest sheds the stalest audio; one `live.md` note on the first drop, one
  "caught up" note when it recovers. Recording unaffected. Post-pass recovers the
  skipped span in `final.md`.
- **Hung (a single decode never returns):** worker blocks inside `whisper_full`
  holding `metalLock`; the drain keeps recording (G1); the queue fills and
  drops; the watchdog flips the `AbortToken` after the deadline; `whisper_full`
  bails, `metalLock` releases, the window is dropped with a note, and the worker
  resumes on the next window (G3).

## 7. Phasing

**Phase 1 — Recording safety (the must-have).** `BoundedFrameQueue`, drain/worker
split, drop-oldest + `live.md` note. Delivers G1, G2, G4. A *hang* still freezes
live transcription for the session (worker stuck holding `metalLock`), but the
recording survives — the hard requirement. Small, reviewable, low-risk.

**Phase 2 — Hang recovery (live-transcript resilience).** `AbortToken` +
`abort_callback` wiring + the worker watchdog + `max_tokens` cap + the
`WindowTranscribing` seam. Delivers G3. Builds on Phase 1 without holding it
hostage.

## 8. Error handling & edge cases

- **End of recording:** the drain finishes the queue; the worker drains
  remaining frames, runs `finish()` on each streamer (final flush), then exits.
  Bound the post-stop flush so a hang at end-of-stream can't stall shutdown
  (reuse the `DiarGate.drain(timeout:)` bounded-wait shape).
- **Cancellation / engine kill:** WAV finalize stays in the drain's `defer`
  (already idempotent), so a kill mid-recording still leaves a valid, refine-able
  WAV — unchanged from today.
- **Both streams lag at once:** independent per-stream queues + notes; `live.md`
  is append-only so duplicate cosmetic notes are harmless (matches the existing
  Fix-A convention).
- **Abort that doesn't take** (a true GPU-kernel hang where control never
  returns to the abort poll): `abort_callback` cannot help. Phase 1's recording
  guarantee still holds; live transcription stays dead until restart. Documented
  limitation; the `max_tokens` cap reduces the window for this.
- **Ordering in `live.md`:** utterances (from the worker) and gap notes (from the
  drain) both go through the serial `LiveSink` actor and carry timestamps; mild
  interleaving is acceptable in the live view and does not affect `final.md`.

## 9. Testing strategy

- **`BoundedFrameQueue` unit tests:** enqueue/dequeue, drop-oldest at cap,
  dropped-duration accounting, finish() unblocks a waiting consumer, the
  "caught up" edge fires once.
- **Drain recording-safety test (Phase 1):** inject a `WindowTranscribing` stub
  that blocks; feed a fixture stream; assert WAV sample count == frames fed
  (no recording loss) and the queue stays at its cap (bounded memory).
- **Drop-note test:** stub slower than real time; assert exactly one "fell
  behind" note and one "caught up" note per episode in `live.md`.
- **Watchdog test (Phase 2):** stub whose `transcribeWindow` blocks until the
  `AbortToken` is cancelled; assert the watchdog fires within ~deadline, the
  window is dropped, and a subsequent window returns normally.
- **`AbortToken` plumbing test:** a real `transcribeWindow` call with a
  pre-cancelled token returns promptly (verifies `abort_callback` is wired) —
  CPU backend (`useGPU: false`) per the test posture.
- All run under the narrow filters (`UnitTests`, `Streaming`, `LiveRunner`,
  `Transcription`) per CLAUDE.md; no failing/ungated tests.

## 10. Config / tunables (defaults; all overridable)

- `BoundedFrameQueue` capacity: **~30 s** of audio per stream (aligns with the
  existing 2-window ≈ 16 s anchor-advance backpressure).
- Watchdog decode deadline (Phase 2): **~10 s**.
- `max_tokens` per window (Phase 2): a validated cap (replacing `0`/unlimited).
- Existing `windowDuration` (8 s) / `stepInterval` (2 s) unchanged.

## 11. Invariants respected

- **Hard Invariant #7:** new logs/notes contain no filesystem paths.
- **Public surfaces:** `live.md` gains best-effort drop notes only (append-only,
  R36 preserved); `final.md` and `events/*.jsonl` unchanged. (Optionally emitting
  a structured drop/abort event to `events/*.jsonl` is deferred — adding an event
  type is a public-surface commitment out of scope here.)
- **Test posture:** no failing tests; new work gated behind narrow filters.

## 12. Open questions / future

- Exact `max_tokens` cap — validate against dense real windows before locking it.
- Capture-daemon unbounded socket queue — separate latent gap, not addressed here
  (the engine draining promptly should keep it from triggering).
- Whether to surface a structured `events/*.jsonl` entry for drops/aborts (public
  surface; deferred).
