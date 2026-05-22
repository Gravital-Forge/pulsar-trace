# Live Transcription Pipeline Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the recording (WAVs) immune to a wedged/slow whisper decode, and let live transcription recover after a single decode hangs — by splitting the engine's single live run loop into a recording-safe drain and a best-effort whisper worker connected by bounded queues, with a per-decode abort-watchdog.

**Architecture:** Today `LiveRunner.run` does WAV-write and the synchronous `whisper_full` decode in sequence on one loop, so a hung decode stops the recording. This plan moves the WAV-write (the durable recording) onto a drain task that never calls whisper, feeds whisper through bounded per-stream queues (drop-oldest on overflow, with a `live.md` note), and wraps each decode in a watchdog wired to whisper's `abort_callback` so a hang is aborted and the worker resumes. A two-stage watchdog also *monitors* the unrecoverable case (an abort that never takes).

**Tech Stack:** Swift 6.2 (actors, `AsyncStream`, `NSLock`), whisper.cpp via the `CWhisper` module (`whisper_full_params.abort_callback` / `.max_tokens`), Swift Testing.

**Source spec:** `docs/specs/2026-05-22-live-pipeline-decoupling-design.md` (read it first).

**Build/test rules (CLAUDE.md):** `swift build` / `swift test` must be run **bare** (no pipes/redirects/`&&`) **with `dangerouslyDisableSandbox: true`**. `--filter PipelineTests` is known-flaky; use the narrow filters named in each task. Every test must pass or be explicitly gated — no red suite.

**Phasing:** Tasks 1–4 are **Phase 1 (recording safety — the must-have)**. Tasks 5–6 are **Phase 2 (hang recovery + monitoring)**. Task 7 is final verification. Phase 1 is independently shippable: after Task 4 the recording can never be lost to a whisper hang, though a hang still freezes *live* transcription until end-of-recording.

---

## File Structure

**New files:**
- `Sources/PulsarTraceEngine/Transcription/WindowTranscribing.swift` — protocol seam over `WhisperTranscriber.transcribeWindow` so a stub (slow/hanging/abort-honoring) can be injected. (Task 1)
- `Sources/PulsarTraceEngine/Transcription/AbortToken.swift` — lock-protected cancellation flag wired to whisper's `abort_callback`. (Task 2)
- `Sources/PulsarTraceEngine/Streaming/BoundedFrameQueue.swift` — bounded, drop-oldest, async-dequeue frame buffer (one instance per stream). (Task 3)
- `Sources/PulsarTraceEngine/Streaming/DecodeWatchdog.swift` — two-stage per-decode watchdog (deadline → abort; abort-grace → monitor warning). (Task 5/6)
- `Tests/UnitTests/AbortTokenTests.swift`, `Tests/UnitTests/BoundedFrameQueueTests.swift`, `Tests/UnitTests/DecodeWatchdogTests.swift` — unit coverage.
- `Tests/PipelineTests/WhisperAbortTests.swift` — real-whisper abort proof (needs `WhisperTestGate`).

**Modified files:**
- `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift` — conform to `WindowTranscribing`; add `abort:`/`max_tokens` to `transcribeWindow`. (Tasks 1–2)
- `Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift` — depend on `WindowTranscribing`; thread `abort:` through `ingest`→`runWindow`. (Tasks 1, 5)
- `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift` — split `run` into drain + worker; WAV-first ordering; integrate queues + watchdog + monitor. (Tasks 4–6)
- `Tests/PipelineTests/LiveRunnerResilienceTests.swift` — add recording-safety, drop-note, watchdog, and monitor tests + the test doubles. (Tasks 4–6)

---

## Task 1: `WindowTranscribing` protocol seam (no behavior change)

Introduce a protocol over the single method the live path uses, so tests can inject a stub. Pure refactor — production behavior is identical.

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/WindowTranscribing.swift`
- Modify: `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift` (add conformance, ~line 95 declaration)
- Modify: `Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift:100` (`transcriber` property type) and `:133-141` (init param type)
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift:104-110` (`run` param types) and `:155-164` (streamer construction)
- Test: `Tests/UnitTests/WindowTranscribingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnitTests/WindowTranscribingTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("WindowTranscribing seam")
struct WindowTranscribingTests {

    /// A stub conforming to the seam — proves the protocol exists and is usable
    /// without a real whisper context.
    final class StubWindowTranscriber: WindowTranscribing, @unchecked Sendable {
        func transcribeWindow(
            _ samples: [Float],
            windowStart: Duration,
            options: WhisperTranscriber.Options,
            abort: AbortToken?
        ) throws -> TranscriptionResult {
            TranscriptionResult(
                segments: [TranscriptSegment(
                    start: windowStart, end: windowStart, text: "stub")],
                language: "en")
        }
    }

    @Test("a stub can stand in for the window transcriber")
    func stubConforms() throws {
        let stub: any WindowTranscribing = StubWindowTranscriber()
        let result = try stub.transcribeWindow(
            [0.1, 0.2], windowStart: .seconds(1), options: .init(), abort: nil)
        #expect(result.segments.first?.text == "stub")
    }
}
```

> Note: `AbortToken` is created in Task 2. For Task 1, temporarily declare the
> protocol's `abort` parameter as `AbortToken?` and add a minimal placeholder
> `AbortToken` in the same file (replaced properly in Task 2). To keep Task 1
> self-contained, instead use `abort: AnyObject?` here is **not** allowed (no
> placeholders) — so create the real `AbortToken` now as part of Step 3 below.

- [ ] **Step 2: Run the test to verify it fails**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter WindowTranscribing`
Expected: FAIL — `cannot find 'WindowTranscribing' in scope` / `cannot find 'AbortToken' in scope`.

- [ ] **Step 3: Create the protocol (and the real `AbortToken`, used by Task 2 too)**

Create `Sources/PulsarTraceEngine/Transcription/WindowTranscribing.swift`:

```swift
import Foundation

/// The single decode operation the live streaming path depends on.
///
/// Extracted as a protocol so the live pipeline can be driven by a test double
/// (a slow, hanging, or abort-honoring stub) without a real `whisper_context`.
/// `WhisperTranscriber` is the production conformer.
///
/// Not `Sendable`: a real conformer owns a non-`Sendable` `whisper_context` and
/// must be driven from one task/queue at a time.
public protocol WindowTranscribing: AnyObject {
    /// Decode one streaming window. `abort`, when non-nil, lets a watchdog
    /// interrupt a hung/runaway decode (see `AbortToken`); `nil` disables it.
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperTranscriber.Options,
        abort: AbortToken?
    ) throws -> TranscriptionResult
}
```

Create `Sources/PulsarTraceEngine/Transcription/AbortToken.swift` (full version — Task 2 wires it into whisper):

```swift
import Foundation

/// A one-way cancellation flag handed to a whisper decode so a watchdog on
/// another task can interrupt it. Lock-protected (not an actor) so the
/// decode's `abort_callback` can read it synchronously from whisper's compute
/// thread without suspending. Once cancelled it stays cancelled.
public final class AbortToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { _cancelled } }

    public func cancel() { lock.withLock { _cancelled = true } }
}
```

- [ ] **Step 4: Conform `WhisperTranscriber` and update `transcribeWindow` signature**

In `WhisperTranscriber.swift`, change the type declaration (line ~95) to conform:

```swift
public final class WhisperTranscriber: WindowTranscribing {
```

Change `transcribeWindow` (line 485) to add the `abort:` parameter (ignored for now — wired in Task 2). New signature:

```swift
    public func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: Options = Options(),
        abort: AbortToken? = nil
    ) throws -> TranscriptionResult {
```

Leave the body unchanged in this task. (The default `abort: nil` keeps every existing call site compiling.)

- [ ] **Step 5: Point `StreamingTranscriber` and `LiveRunner` at the protocol**

In `StreamingTranscriber.swift`:
- Line 100: change `private let transcriber: WhisperTranscriber` → `private let transcriber: any WindowTranscribing`
- Lines 133-141: change the init param `transcriber: WhisperTranscriber` → `transcriber: any WindowTranscribing`

In `LiveRunner.swift`, `run` (lines 104-110): change the two transcriber params:

```swift
    func run(
        systemTranscriber: any WindowTranscribing,
        micTranscriber: (any WindowTranscribing)?,
        systemSource: some AudioFrameSource,
        micSource: (any AudioFrameSource)?,
        liveDiarizer: (any LiveDiarizing)?
    ) async throws -> StreamingPipeline.Output {
```

The streamer construction at lines 155-164 already passes `systemTranscriber` / `micTranscriber` into `StreamingTranscriber(transcriber:...)` — no change needed beyond the types now matching.

- [ ] **Step 6: Run the test to verify it passes, and the whole engine still builds**

Run: `swift build` → Expected: `Build complete!`
Run: `swift test --filter WindowTranscribing` → Expected: PASS (1 test)
Run: `swift test --filter Streaming` → Expected: PASS (no regressions)
Run: `swift test --filter LiveRunner` → Expected: PASS (no regressions)

- [ ] **Step 7: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/WindowTranscribing.swift Sources/PulsarTraceEngine/Transcription/AbortToken.swift Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift Sources/PulsarTraceEngine/Streaming/LiveRunner.swift Tests/UnitTests/WindowTranscribingTests.swift
git commit -m "refactor: WindowTranscribing protocol seam + AbortToken type (no behavior change)"
```

---

## Task 2: Wire `abort_callback` + `max_tokens` into the real decode

Make a real `whisper_full` interruptible, and prove it against real whisper on the CPU backend.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift:485-538` (`transcribeWindow`)
- Test: `Tests/UnitTests/AbortTokenTests.swift` (pure-logic), `Tests/PipelineTests/WhisperAbortTests.swift` (real whisper)

- [ ] **Step 1: Write the failing unit test for `AbortToken`**

Create `Tests/UnitTests/AbortTokenTests.swift`:

```swift
import Testing
@testable import PulsarTraceEngine

@Suite("AbortToken")
struct AbortTokenTests {
    @Test("starts un-cancelled, latches on cancel")
    func latches() {
        let t = AbortToken()
        #expect(t.isCancelled == false)
        t.cancel()
        #expect(t.isCancelled == true)
        t.cancel()  // idempotent
        #expect(t.isCancelled == true)
    }
}
```

- [ ] **Step 2: Run it to verify it passes** (the type exists from Task 1)

Run: `swift test --filter AbortToken` → Expected: PASS.

> This unit test passes immediately — it documents the contract. The real
> proof is the whisper test below.

- [ ] **Step 3: Write the failing real-whisper abort proof**

Create `Tests/PipelineTests/WhisperAbortTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

/// Proves the `abort_callback` plumbing genuinely interrupts a real
/// `whisper_full` decode on the CPU backend — the core of the watchdog
/// mechanism. `.serialized` because each test builds a `WhisperTranscriber`
/// (one whisper context per process, D8).
@Suite("WhisperAbort", .serialized)
struct WhisperAbortTests {

    /// A buffer long enough that a full decode takes meaningful time, so a
    /// pre-cancelled abort is an obvious contrast. 20 s of low white noise at
    /// 16 kHz: non-silent (passes any peak gate) and gives whisper real work.
    private func longBuffer() -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<(16_000 * 20)).map { _ in
            Float.random(in: -0.05...0.05, using: &rng)
        }
    }

    @Test("a pre-cancelled abort token returns far faster than a full decode, and the context still works after")
    func preCancelledAbortInterruptsRealDecode() async throws {
        let modelURL = try await WhisperTestGate.model(ModelCatalog.base)
        try await WhisperTestGate.run {
            let t = try WhisperTestTranscriber.make(modelURL: modelURL)
            let audio = longBuffer()

            // Baseline: a full decode with no abort.
            let fullStart = ContinuousClock.now
            _ = try t.transcribeWindow(
                audio, windowStart: .zero, options: .init(), abort: nil)
            let full = ContinuousClock.now - fullStart

            // Same decode, pre-cancelled: whisper bails on its first abort poll.
            let token = AbortToken()
            token.cancel()
            let abortStart = ContinuousClock.now
            _ = try? t.transcribeWindow(
                audio, windowStart: .zero, options: .init(), abort: token)
            let aborted = ContinuousClock.now - abortStart

            // The aborted call is dramatically shorter than the full decode.
            #expect(aborted < full / 4,
                    "aborted=\(aborted) was not << full=\(full)")

            // The context is still usable — the abort released metalLock cleanly.
            let after = try t.transcribeWindow(
                audio, windowStart: .zero, options: .init(), abort: AbortToken())
            #expect(after.language != "")
        }
    }
}
```

- [ ] **Step 4: Run it to verify it fails**

Run: `swift test --filter WhisperAbort` → Expected: FAIL — the aborted call currently runs a full decode (abort not wired), so `aborted < full/4` is false.

- [ ] **Step 5: Wire abort + max_tokens into `transcribeWindow`**

In `WhisperTranscriber.swift`, inside `transcribeWindow`, after the existing param setup (after line 508 `params.no_speech_thold = ...`) and before the `metalLock.lock()` (line 513), add the abort hook and a per-segment token cap:

```swift
        // Per-segment token cap: a window is ≤ 8 s of speech, so a few hundred
        // tokens is generous; an unbounded (0) cap lets a degenerate decode
        // loop spin. Bounds a runaway even between abort polls. (Validate the
        // value against dense real windows — design §12.)
        params.max_tokens = Int32(Self.streamingMaxTokensPerSegment)

        // Abort hook: a watchdog on another task flips `abort.cancel()`; whisper
        // polls this between ggml graph nodes and decode steps and returns early,
        // releasing metalLock. The closure is @convention(c) (no captures) and
        // reads the token through the user-data pointer.
        if let abort {
            params.abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<AbortToken>
                    .fromOpaque(userData).takeUnretainedValue().isCancelled
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        }
```

Add the constant near the other static members (after line 99 `metalLock`):

```swift
    /// Per-segment token cap for the streaming window path (whisper.h `max_tokens`).
    /// Bounds a degenerate/runaway decode. 0 = unlimited (old behavior).
    static let streamingMaxTokensPerSegment = 256
```

> `abort` is held alive by the caller across the synchronous `transcribeWindow`
> call, so `passUnretained` is safe — the pointer is only dereferenced inside
> `whisper_full`, which returns before the call does.

- [ ] **Step 6: Run the proof + a no-truncation sanity check**

Run: `swift test --filter WhisperAbort` → Expected: PASS.

Add one more test to `WhisperAbortTests` to confirm the `max_tokens` cap does not gut normal output, then run it:

```swift
    @Test("max_tokens cap still yields a normal transcript on a speech fixture")
    func capDoesNotTruncateNormalSpeech() async throws {
        let modelURL = try await WhisperTestGate.model(ModelCatalog.base)
        try await WhisperTestGate.run {
            let t = try WhisperTestTranscriber.make(modelURL: modelURL)
            let samples = try WAVTestReader.samples(
                FixtureLocator.audio("single-speaker-30s.wav"))
            let window = Array(samples.prefix(16_000 * 8))  // one 8 s window
            let r = try t.transcribeWindow(
                window, windowStart: .zero, options: .init(), abort: nil)
            #expect(!r.segments.isEmpty)
        }
    }
```

> If a `WAVTestReader` helper does not exist, reuse whatever the existing
> `TranscriptionPipelineTests` use to load fixture samples (grep
> `FixtureLocator.audio` in `Tests/`); the point is one real 8 s window decodes
> to non-empty segments with the cap in place.

Run: `swift test --filter WhisperAbort` → Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift Tests/UnitTests/AbortTokenTests.swift Tests/PipelineTests/WhisperAbortTests.swift
git commit -m "feat: interruptible whisper decode via abort_callback + max_tokens cap"
```

---

## Task 3: `BoundedFrameQueue` — bounded, drop-oldest, async dequeue

A per-stream buffer between the drain (producer) and the whisper worker (consumer). Non-blocking enqueue with drop-oldest; async dequeue that suspends when empty; `finish()` ends it; tracks dropped audio so the worker can note it.

**Files:**
- Create: `Sources/PulsarTraceEngine/Streaming/BoundedFrameQueue.swift`
- Test: `Tests/UnitTests/BoundedFrameQueueTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/UnitTests/BoundedFrameQueueTests.swift`:

```swift
import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("BoundedFrameQueue")
struct BoundedFrameQueueTests {

    private func frame(_ i: Int) -> AudioFrame { .silence(sequenceIndex: i) }

    @Test("FIFO delivery in order while under capacity")
    func fifoUnderCapacity() async {
        let q = BoundedFrameQueue(capacityFrames: 8)
        q.enqueue(frame(0)); q.enqueue(frame(1)); q.enqueue(frame(2))
        q.finish()
        var got: [Int] = []
        while let f = await q.dequeue() { got.append(f.sequenceIndex) }
        #expect(got == [0, 1, 2])
    }

    @Test("drops the oldest when full, keeping the newest, and counts the drop")
    func dropOldestWhenFull() async {
        let q = BoundedFrameQueue(capacityFrames: 2)
        q.enqueue(frame(0))   // [0]
        q.enqueue(frame(1))   // [0,1]
        q.enqueue(frame(2))   // full → drop 0 → [1,2]
        q.enqueue(frame(3))   // full → drop 1 → [2,3]
        q.finish()
        var got: [Int] = []
        while let f = await q.dequeue() { got.append(f.sequenceIndex) }
        #expect(got == [2, 3])
        #expect(q.droppedFrameCount == 2)
    }

    @Test("dequeue suspends until a frame arrives, then resumes")
    func dequeueSuspendsThenResumes() async {
        let q = BoundedFrameQueue(capacityFrames: 4)
        let consumer = Task { () -> Int? in
            await q.dequeue()?.sequenceIndex
        }
        // Nothing enqueued yet; give the consumer time to suspend.
        try? await Task.sleep(for: .milliseconds(50))
        q.enqueue(frame(42))
        #expect(await consumer.value == 42)
    }

    @Test("finish unblocks a waiting consumer with nil")
    func finishUnblocksConsumer() async {
        let q = BoundedFrameQueue(capacityFrames: 4)
        let consumer = Task { await q.dequeue()?.sequenceIndex }
        try? await Task.sleep(for: .milliseconds(50))
        q.finish()
        #expect(await consumer.value == nil)
    }

    @Test("the dropped→recovered edge fires once per episode")
    func droppedEdgeFiresOncePerEpisode() async {
        let q = BoundedFrameQueue(capacityFrames: 1)
        // Episode 1: overflow, then drain to empty.
        q.enqueue(frame(0)); q.enqueue(frame(1))   // drops 0
        #expect(q.consumeDropEpisodeStarted() == true)   // edge: dropping began
        #expect(q.consumeDropEpisodeStarted() == false)  // not re-reported
        _ = await q.dequeue()                            // drain to empty → caught up
        #expect(q.consumeCaughtUp() == true)
        #expect(q.consumeCaughtUp() == false)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter BoundedFrameQueue` → Expected: FAIL — `cannot find 'BoundedFrameQueue' in scope`.

- [ ] **Step 3: Implement `BoundedFrameQueue`**

Create `Sources/PulsarTraceEngine/Streaming/BoundedFrameQueue.swift`:

```swift
import Foundation

/// A bounded hand-off buffer from the recording-safe drain (producer) to the
/// whisper worker (consumer), one instance per stream.
///
/// `enqueue` never blocks the producer: when the buffer is full it drops the
/// **oldest** frame so the live transcript tracks *now* rather than replaying
/// stale audio (the dropped span is recovered by the offline post-pass). The
/// consumer `await`s `dequeue`, which suspends while empty and returns `nil`
/// once `finish()` has been called and the buffer is drained.
///
/// Lock-protected (not an actor) so `enqueue` is synchronous and can be called
/// from the drain's per-frame hot path without suspension. A single waiting
/// consumer is supported (the design uses one worker).
public final class BoundedFrameQueue: @unchecked Sendable {

    private let lock = NSLock()
    private var buffer: [AudioFrame] = []
    private let capacityFrames: Int
    private var finished = false
    private var waiter: CheckedContinuation<AudioFrame?, Never>?

    private var _droppedFrameCount = 0
    private var dropping = false           // currently in a drop episode
    private var dropEpisodeStartedEdge = false
    private var caughtUpEdge = false

    public init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        self.capacityFrames = capacityFrames
    }

    /// Total frames dropped over the queue's lifetime.
    public var droppedFrameCount: Int { lock.withLock { _droppedFrameCount } }

    /// Non-blocking. Hands the frame to a waiting consumer if one is parked,
    /// else buffers it, dropping the oldest frame when at capacity.
    public func enqueue(_ frame: AudioFrame) {
        let resume: (CheckedContinuation<AudioFrame?, Never>)? = lock.withLock {
            if let w = waiter {
                waiter = nil
                // Hand directly to the parked consumer.
                pendingHandoff = frame
                return w
            }
            if buffer.count >= capacityFrames {
                buffer.removeFirst()
                _droppedFrameCount += 1
                if !dropping { dropping = true; dropEpisodeStartedEdge = true }
            }
            buffer.append(frame)
            return nil
        }
        if let resume {
            let f = pendingHandoff
            pendingHandoff = nil
            resume.resume(returning: f)
        }
    }

    // Scratch slot for a direct producer→consumer hand-off under the lock.
    private var pendingHandoff: AudioFrame?

    /// Suspends until a frame is available or the queue is finished+empty.
    public func dequeue() async -> AudioFrame? {
        await withCheckedContinuation { (cont: CheckedContinuation<AudioFrame?, Never>) in
            let immediate: AudioFrame?? = lock.withLock {
                if !buffer.isEmpty {
                    let f = buffer.removeFirst()
                    if buffer.isEmpty && dropping {
                        dropping = false; caughtUpEdge = true
                    }
                    return .some(f)        // resume now with a frame
                }
                if finished { return .some(nil) }   // resume now with nil
                waiter = cont                         // park
                return .none
            }
            if let immediate { cont.resume(returning: immediate) }
        }
    }

    /// Mark end-of-stream. A parked consumer is resumed with `nil` once the
    /// buffer drains; if already empty it is resumed immediately.
    public func finish() {
        let resume: (CheckedContinuation<AudioFrame?, Never>)? = lock.withLock {
            finished = true
            if buffer.isEmpty, let w = waiter {
                waiter = nil
                pendingHandoff = nil
                return w
            }
            return nil
        }
        resume?.resume(returning: nil)
    }

    /// One-shot read of "a drop episode just began" (true at most once until a
    /// matching `consumeCaughtUp`). Lets the worker emit the live.md note once.
    public func consumeDropEpisodeStarted() -> Bool {
        lock.withLock {
            defer { dropEpisodeStartedEdge = false }
            return dropEpisodeStartedEdge
        }
    }

    /// One-shot read of "the buffer drained back to empty after dropping".
    public func consumeCaughtUp() -> Bool {
        lock.withLock {
            defer { caughtUpEdge = false }
            return caughtUpEdge
        }
    }
}
```

> Concurrency note for the implementer: this supports exactly one parked
> consumer (the single worker). The direct hand-off path (`pendingHandoff`)
> keeps a frame from being buffered when a consumer is already waiting. Verify
> with the build that `CheckedContinuation` capture compiles cleanly; if the
> `pendingHandoff` scratch field trips Sendable analysis, fold the handed-off
> frame into the return value of the `withLock` closure instead.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter BoundedFrameQueue` → Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Streaming/BoundedFrameQueue.swift Tests/UnitTests/BoundedFrameQueueTests.swift
git commit -m "feat: BoundedFrameQueue (drop-oldest, async dequeue, drop accounting)"
```

---

## Task 4: Split `LiveRunner.run` into drain + worker (Phase 1 recording safety)

The big one. Move the WAV write + diarization onto a drain that never calls whisper, route frames through two `BoundedFrameQueue`s, and run whisper on a single worker task. WAV append happens first for every frame.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift` (`run`, lines 110-472)
- Test: `Tests/PipelineTests/LiveRunnerResilienceTests.swift` (add tests + a `BlockingWindowTranscriber` double)

### Structure to implement

`run` becomes:

1. **Setup** (unchanged): `sink`, merged stream + `readers` task (pumps + ticker), `diarBuffer`/`diarState`/`diarGate`, WAV writers + finalize `defer`, phase tracker + heartbeat.
2. **Per-stream queues:**
   ```swift
   let systemQueue = BoundedFrameQueue(capacityFrames: queueCapacityFrames)
   let micQueue = hasMic ? BoundedFrameQueue(capacityFrames: queueCapacityFrames) : nil
   ```
   where `queueCapacityFrames` is `durationToSamples(queueCapacity) / AudioFormat.samplesPerFrame`, `queueCapacity` a new init param defaulting to `.seconds(30)`.
3. **Worker task** owns both `StreamingTranscriber`s and consumes the queues (see worker code below).
4. **Drain loop** (`for await item in merged`): WAV-first, then diar (system), then `queue.enqueue(frame)`. Pause/resume/tick → the existing silence-watchdog/gap-note logic (unchanged). `.ended(tag)` → `queue.finish()` for that stream (the worker flushes on the nil dequeue). Keep the exit condition (`systemDone && micDone`).
5. **Teardown:** after the drain loop, `await worker.value` (returns the system stream's detected language), then the existing `diarGate.drain`, `readers.value`, `sink.noteSystemLanguage`, `sink.stats` → `Output`.

### Worker (single task servicing both queues via a shared wakeup)

Add this as a local in `run`, after the queues and streamers are created. It multiplexes the two queues with one consumer (honors the design's single-worker decision) using a wakeup `AsyncStream` (its unbounded buffer makes lost wakeups impossible):

```swift
// Wakeup signal: each queue posts on enqueue/finish so the worker re-checks.
let (wake, wakeCont) = AsyncStream.makeStream(of: Void.self)

// The worker owns the streamers (non-Sendable) — created here and never touched
// outside this task.
let worker = Task { () -> String in
    var systemEnded = false
    var micEnded = (micQueue == nil)
    let elapsedFrom = startWall

    func drainReady(_ queue: BoundedFrameQueue?, _ streamer: StreamingTranscriber?,
                    isMic: Bool) async -> Bool {
        guard let queue, let streamer else { return true }   // treated as ended
        var ended = false
        while let frame = queue.tryDequeueNonSuspending() {
            let elapsed = ContinuousClock.now - elapsedFrom
            for utt in streamer.ingest(frame: frame, realTimeElapsed: elapsed) {
                if isMic {
                    await sink.appendMicUtterance(utt, realElapsed: elapsed)
                } else {
                    let label = await resolveSystemLabel(
                        for: utt, diarState: diarState, diarizer: liveDiarizer)
                    await sink.appendSystemUtterance(utt, label: label, realElapsed: elapsed)
                }
            }
        }
        if queue.isFinishedAndEmpty {
            let elapsed = ContinuousClock.now - elapsedFrom
            for utt in streamer.finish() {
                if isMic {
                    await sink.appendMicUtterance(utt, realElapsed: elapsed, isFlush: true)
                } else {
                    let label = await resolveSystemLabel(
                        for: utt, diarState: diarState, diarizer: liveDiarizer)
                    await sink.appendSystemUtterance(
                        utt, label: label, realElapsed: elapsed, isFlush: true)
                }
            }
            ended = true
        }
        return ended
    }

    while true {
        if !systemEnded { systemEnded = await drainReady(systemQueue, systemStreamer, isMic: false) }
        if !micEnded { micEnded = await drainReady(micQueue, micStreamer, isMic: true) }
        if systemEnded && micEnded { break }
        _ = await wakeIterator.next()   // sleeps until a queue posts a wakeup
    }
    return systemStreamer.detectedLanguage ?? "en"
}
```

This requires two small additions to `BoundedFrameQueue` (Task 3 file) plus wiring the wakeup. Implement them as Step 1 below.

- [ ] **Step 1: Extend `BoundedFrameQueue` with the worker-facing helpers + wakeup**

Add to `BoundedFrameQueue` an injectable wakeup closure and the non-suspending helpers the worker uses. In `BoundedFrameQueue.swift`:

```swift
    /// Posted (if set) whenever a frame is enqueued or the queue is finished, so
    /// a worker multiplexing several queues can re-check without a parked
    /// per-queue continuation. Set once at construction by the owner.
    public var onActivity: (@Sendable () -> Void)?

    /// Non-suspending dequeue for a worker that parks on an external wakeup
    /// instead of `dequeue()`. Returns nil when momentarily empty.
    public func tryDequeueNonSuspending() -> AudioFrame? {
        lock.withLock {
            guard !buffer.isEmpty else { return nil }
            let f = buffer.removeFirst()
            if buffer.isEmpty && dropping { dropping = false; caughtUpEdge = true }
            return f
        }
    }

    /// True once `finish()` was called and every buffered frame has been taken.
    public var isFinishedAndEmpty: Bool { lock.withLock { finished && buffer.isEmpty } }
```

Call `onActivity?()` at the end of `enqueue` and at the end of `finish` (outside the lock). Wire it in `run`:

```swift
systemQueue.onActivity = { wakeCont.yield(()) }
micQueue?.onActivity = { wakeCont.yield(()) }
```

And take the wake iterator before the worker loop: `var wakeIterator = wake.makeAsyncIterator()`.

> The worker uses `tryDequeueNonSuspending` + the shared `wake` stream rather
> than the single-consumer `dequeue()` — because one worker drains *two* queues.
> `dequeue()`/the parked-continuation path stays for the unit tests and any
> future single-queue consumer.

- [ ] **Step 2: Write the failing recording-safety test**

Add to `LiveRunnerResilienceTests.swift` (new test + the blocking double at the bottom):

```swift
    // MARK: - Recording safety — WAV is never blocked by whisper

    @Test("a wedged whisper decode never stalls the WAV recording")
    func wedgedWhisperDoesNotStallRecording() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A transcriber whose every decode blocks forever — the exact wedge.
        let blocking = BlockingWindowTranscriber()
        let source = ControllableSource()
        let systemWAV = folder.appendingPathComponent(RecordingFolder.FileName.audioSystem)

        let (runner, writer, _) = makeRunner(folder: folder)
        try await writer.start()

        let runTask = Task {
            try await runner.run(
                systemTranscriber: blocking,
                micTranscriber: nil,
                systemSource: source,
                micSource: nil,
                liveDiarizer: nil)
        }

        // Feed 100 frames (2 s of audio — well past one 8 s? no: 100*20ms=2s,
        // enough to trigger a decode that then blocks). The decode wedges, but
        // the drain must keep writing every frame to the WAV.
        for i in 0..<100 { await source.yieldFrame(.silence(sequenceIndex: i)) }

        // Give the drain time to write while whisper is wedged.
        try await Task.sleep(for: .milliseconds(400))

        // The system WAV on disk already reflects the fed frames, even though
        // whisper has decoded nothing. 100 frames * 320 samples * 4 bytes
        // + 44-byte header = 128_044 bytes; assert it is at least most of that.
        let size = (try? Data(contentsOf: systemWAV))?.count ?? 0
        #expect(size >= 100 * AudioFormat.samplesPerFrame * 4,
                "WAV did not grow while whisper was wedged; size=\(size)")

        // End the stream; the run must still return (the worker is abandoned
        // mid-decode, but the drain finishes the queues and exits).
        await source.finish()
        // The blocking decode never returns, so the worker never sets the
        // language; the run still completes because teardown does not depend on
        // the worker finishing in Phase 1. (If `await worker.value` would block,
        // see Step 5 — teardown must not wait unbounded on the worker.)
        _ = try await withTimeoutOrNil(seconds: 5) { try await runTask.value }
        await writer.finish()

        let finalSize = (try? Data(contentsOf: systemWAV))?.count ?? 0
        #expect(finalSize >= 100 * AudioFormat.samplesPerFrame * 4)
    }
```

Add the blocking double + a small timeout helper to the test doubles section:

```swift
/// A `WindowTranscribing` whose every decode blocks forever — the live wedge.
final class BlockingWindowTranscriber: WindowTranscribing, @unchecked Sendable {
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperTranscriber.Options,
        abort: AbortToken?
    ) throws -> TranscriptionResult {
        // Block the worker thread the way a wedged whisper_full does. Honor the
        // abort token if it is ever set (Phase 2), else spin-sleep forever.
        while abort?.isCancelled != true {
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw WhisperTranscriber.TranscribeError.transcriptionFailed(-999)
    }
}

/// Run `body`, returning nil if it does not finish within `seconds`.
func withTimeoutOrNil<T: Sendable>(
    seconds: Double, _ body: @escaping @Sendable () async throws -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await body() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds)); return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter LiveRunner` → Expected: FAIL — today the WAV write is behind the synchronous decode, so the wedged decode prevents WAV growth (size stays at the 44-byte header) **or** the test does not compile because `run` does not yet take `any WindowTranscribing` with the new structure. Confirm the failure is the WAV-size assertion, not a compile error unrelated to this task.

- [ ] **Step 4: Refactor `run` — WAV-first drain + enqueue**

Rewrite the `for await item in merged` body so each frame case is **WAV-first, no whisper**. Replace the `.frame(.system, …)` case (lines 265-338) with:

```swift
            case .frame(.system, let frame):
                frameIdx += 1
                phase.set("frame-system-received", frameIndex: frameIdx)
                let systemFrameNow = ContinuousClock.now
                // WAV FIRST — the recording must never sit behind anything.
                phase.set("wav-append-system")
                appendToWAV(systemWAVWriter, frame.samples, stream: "system")
                // Now the (cheap) sink/diar bookkeeping.
                if systemGapAnnotated {
                    systemGapAnnotated = false
                    phase.set("await-sink-appendGap-system-resumed")
                    await sink.appendGap(.resumed(systemFrameNow - lastSystemActivity))
                }
                lastSystemActivity = systemFrameNow
                // Diarization stays on the drain (fast: detached dispatch, Fix B/C).
                diarBuffer.append(contentsOf: frame.samples)
                if let liveDiarizer,
                   diarTotalSamples - lastDiarEnd >= diarStep,
                   diarTotalSamples >= diarWindow {
                    let loAbs = max(0, diarTotalSamples - diarWindow)
                    let lo = loAbs - diarBufferBase
                    lastDiarEnd = diarTotalSamples
                    phase.set("await-diarGate-tryAcquire")
                    if lo >= 0, lo <= diarBuffer.count, await diarGate.tryAcquire() {
                        let windowSamples = Array(diarBuffer[lo...])
                        let windowStart = samplesToDuration(loAbs)
                        Task.detached {
                            let spans = await liveDiarizer.diarizeWindow(
                                samples: windowSamples, windowStart: windowStart)
                            await diarState.merge(spans)
                            await diarGate.release()
                        }
                    }
                }
                let diarKeep = 2 * diarWindow
                if diarBuffer.count > diarKeep {
                    let trim = diarBuffer.count - diarKeep
                    diarBuffer.removeFirst(trim)
                    diarBufferBase += trim
                }
                diarBufferProbe?(diarBuffer.count)
                // Hand off to whisper — never blocks; drops oldest if the worker
                // is behind. Note the drop episode once.
                phase.set("enqueue-system")
                systemQueue.enqueue(frame)
                noteDropEdges(systemQueue, stream: "system", sink: sink)
```

Replace the `.frame(.mic, …)` case (lines 340-362) with:

```swift
            case .frame(.mic, let frame):
                frameIdx += 1
                phase.set("frame-mic-received", frameIndex: frameIdx)
                let micFrameNow = ContinuousClock.now
                phase.set("wav-append-mic")
                appendToWAV(micWAVWriter, frame.samples, stream: "mic")  // WAV FIRST
                if micGapAnnotated {
                    micGapAnnotated = false
                    phase.set("await-sink-appendGap-mic-resumed")
                    await sink.appendGap(.resumed(micFrameNow - lastMicActivity))
                }
                lastMicActivity = micFrameNow
                if let micQueue {
                    phase.set("enqueue-mic")
                    micQueue.enqueue(frame)
                    noteDropEdges(micQueue, stream: "mic", sink: sink)
                }
```

Replace the `.ended(.system)` case (lines 416-429) with:

```swift
            case .ended(.system):
                phase.set("ended-system")
                systemQueue.finish()    // worker flushes on the nil dequeue
                systemDone = true
```

Replace `.ended(.mic)` (lines 431-441) with:

```swift
            case .ended(.mic):
                phase.set("ended-mic")
                micQueue?.finish()
                micDone = true
```

Leave `.paused(.system)`, `.resumed(.system,…)`, `.paused(.mic)`, `.resumed(.mic,…)`, and `.tick` cases exactly as they are (silence watchdog / gap notes — drain-side, whisper-free).

Add the `noteDropEdges` helper near the other helpers (after `finalizeWAV`):

```swift
    /// Emit a one-time live.md note when a queue starts dropping, and another
    /// when it catches back up. Best-effort; never blocks the drain hot path
    /// beyond a single cheap sink append.
    private func noteDropEdges(
        _ queue: BoundedFrameQueue, stream: String, sink: LiveSink
    ) async {
        if queue.consumeDropEpisodeStarted() {
            logger.warning("live transcription falling behind; dropping \(stream) audio from the live view (recording unaffected)")
            await sink.appendGap(.paused)
        }
        if queue.consumeCaughtUp() {
            await sink.appendGap(.resumed(.zero))
        }
    }
```

> The drop note reuses the existing `appendGap` annotations so `live.md` stays
> append-only (R36) and no new public-surface line type is introduced (design
> §11). The log line carries the stream name only — no paths (Invariant #7).

- [ ] **Step 5: Refactor teardown — bounded wait on the worker**

After the `for await item in merged` loop (replacing lines 449-460), the run must hand off to the worker for the detected language but must **not** hang forever if the worker is wedged in a Phase-1 hang. Replace with:

```swift
        // Both streams ended: let the worker drain remaining frames + flush,
        // bounded so a wedged decode (Phase 1 has no abort yet) cannot hang the
        // run. A timeout here only costs the tail flush + the detected-language
        // refinement; the recording is already safe on disk.
        phase.set("await-worker")
        let detectedLanguage = await withTaskGroup(of: String?.self) { group in
            group.addTask { await worker.value }
            group.addTask {
                try? await Task.sleep(for: self.workerDrainTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? "en"
        }
        worker.cancel()   // abandon a still-wedged worker; recording is safe

        phase.set("await-diarGate-drain")
        await diarGate.drain(timeout: .seconds(2))
        phase.set("await-readers-value")
        _ = await readers.value
        phase.set("await-sink-noteSystemLanguage")
        await sink.noteSystemLanguage(detectedLanguage)
```

Add `workerDrainTimeout` as a new init param: `workerDrainTimeout: Duration = .seconds(10)` (tests inject a short value). Add the matching stored property + init assignment alongside the existing ones (lines 71-101).

> `worker.value` returns `String` (the language), so wrap it as `String?` in the
> race. `worker.cancel()` is harmless when the worker already returned. A
> synchronous wedged decode does not observe cancellation in Phase 1 — that is
> what Task 5's watchdog adds — but the run still returns because of the timeout,
> and the recording is intact.

- [ ] **Step 6: Build, then run it to verify it passes + no regressions**

Run: `swift build` → Expected: `Build complete!` (resolve any Sendable capture errors on the worker closure — the streamers are captured into one `Task` and only touched there; if the compiler objects to capturing `systemStreamer`/`micStreamer`, hold them in a tiny `@unchecked Sendable` box created just before the worker `Task`).
Run: `swift test --filter LiveRunner` → Expected: PASS, including the new `wedgedWhisperDoesNotStallRecording` and all existing Fix A/B/C tests (the silence watchdog, wedged-diarizer, and diarBuffer-bound tests must still pass — the drain still owns all of that).
Run: `swift test --filter Streaming` → Expected: PASS.

- [ ] **Step 7: Add and run the drop-note test**

Add to `LiveRunnerResilienceTests.swift`:

```swift
    @Test("when whisper falls behind, the live view notes the drop and recording is whole")
    func dropNoteOnBacklog() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let liveURL = folder.appendingPathComponent(RecordingFolder.FileName.live)

        let blocking = BlockingWindowTranscriber()   // worker never drains
        let source = ControllableSource()
        // Tiny queue so it overflows almost immediately.
        let (runner, writer, _) = makeRunner(folder: folder, queueCapacity: .milliseconds(200))
        try await writer.start()

        let runTask = Task {
            try await runner.run(
                systemTranscriber: blocking, micTranscriber: nil,
                systemSource: source, micSource: nil, liveDiarizer: nil)
        }
        for i in 0..<200 { await source.yieldFrame(.silence(sequenceIndex: i)) }
        try await Task.sleep(for: .milliseconds(300))
        await source.finish()
        _ = await withTimeoutOrNil(seconds: 5) { try await runTask.value }
        await writer.finish()

        let text = try String(contentsOf: liveURL, encoding: .utf8)
        // A drop episode produced a paused-style annotation in the live view.
        #expect(text.contains("_(recording paused)_"))
    }
```

Add a `queueCapacity` param to the test's `makeRunner` helper (defaulting to `.seconds(30)`) and pass it to `LiveRunner(... queueCapacity: queueCapacity)`. Add the matching `queueCapacity` init param to `LiveRunner` (default `.seconds(30)`), stored and used to compute `queueCapacityFrames`.

Run: `swift test --filter LiveRunner` → Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/PulsarTraceEngine/Streaming/LiveRunner.swift Sources/PulsarTraceEngine/Streaming/BoundedFrameQueue.swift Tests/PipelineTests/LiveRunnerResilienceTests.swift
git commit -m "feat: split LiveRunner into recording-safe drain + whisper worker (Phase 1)"
```

---

## Task 5: Per-decode watchdog — abort a hung decode and resume (Phase 2)

Wrap each worker decode in a deadline; when it overruns, flip the `AbortToken` so whisper bails and the worker continues with the next window.

**Files:**
- Create: `Sources/PulsarTraceEngine/Streaming/DecodeWatchdog.swift`
- Modify: `Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift` (`ingest`/`runWindow` thread `abort:`)
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift` (worker arms the watchdog per ingest)
- Test: `Tests/UnitTests/DecodeWatchdogTests.swift`, `Tests/PipelineTests/LiveRunnerResilienceTests.swift`

- [ ] **Step 1: Write the failing `DecodeWatchdog` unit tests**

Create `Tests/UnitTests/DecodeWatchdogTests.swift`:

```swift
import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

@Suite("DecodeWatchdog")
struct DecodeWatchdogTests {

    @Test("cancels the in-flight token once the decode passes the deadline")
    func cancelsAfterDeadline() async {
        let dog = DecodeWatchdog(
            deadline: .milliseconds(80), abortGrace: .seconds(10),
            logger: .init(label: "test"))
        let token = AbortToken()
        await dog.beginDecode(token: token, stream: "system")
        #expect(token.isCancelled == false)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(token.isCancelled == true)
        await dog.endDecode()
    }

    @Test("does not cancel a decode that finishes before the deadline")
    func noCancelWhenFast() async {
        let dog = DecodeWatchdog(
            deadline: .seconds(5), abortGrace: .seconds(10),
            logger: .init(label: "test"))
        let token = AbortToken()
        await dog.beginDecode(token: token, stream: "system")
        try? await Task.sleep(for: .milliseconds(50))
        await dog.endDecode()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(token.isCancelled == false)
    }

    @Test("warns with a growing age when a decode ignores the abort past the grace window")
    func warnsWhenAbortNotHonored() async {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }
        let dog = DecodeWatchdog(
            deadline: .milliseconds(50), abortGrace: .milliseconds(80),
            logger: logger)
        let token = AbortToken()   // a stub that never reacts to cancel
        await dog.beginDecode(token: token, stream: "mic")
        try? await Task.sleep(for: .milliseconds(400))
        await dog.endDecode()
        let warnings = capture.messages.filter { $0.contains("did not honor abort") }
        #expect(warnings.count >= 2, "expected escalating warnings; got \(capture.messages)")
        let ages = warnings.compactMap { Self.age(from: $0) }
        for i in 1..<ages.count { #expect(ages[i] >= ages[i-1]) }
    }

    private static func age(from m: String) -> Int? {
        guard let r = m.range(of: #"age=([0-9]+)ms"#, options: .regularExpression)
        else { return nil }
        return Int(m[r].dropFirst("age=".count).dropLast(2))
    }
}

// Reuse the capturing handler shape from LiveRunnerPhaseTrackerTests.
private final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock(); private var _m: [String] = []
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey k: String) -> Logger.Metadata.Value? {
        get { metadata[k] } set { metadata[k] = newValue } }
    var messages: [String] { lock.withLock { _m } }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        lock.withLock { _m.append("\(message)") }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter DecodeWatchdog` → Expected: FAIL — `cannot find 'DecodeWatchdog' in scope`.

- [ ] **Step 3: Implement `DecodeWatchdog`**

Create `Sources/PulsarTraceEngine/Streaming/DecodeWatchdog.swift`:

```swift
import Foundation
import Logging

/// Watches the worker's in-flight whisper decode and interrupts a hang.
///
/// Two stages, both driven by one background polling task:
///  1. **deadline** — after this long, flip the decode's `AbortToken` so
///     `whisper_full` bails and releases `metalLock`; the worker drops that
///     window and continues.
///  2. **abort-grace** — if the decode is *still* outstanding this long after
///     the abort was signalled, the abort did not take (a true single-kernel
///     GPU hang). Emit an escalating, greppable warning with a growing age so
///     the unrecoverable case is visible and countable (design §5.6).
///
/// The watchdog runs as its own task, so it keeps observing even while the
/// worker is blocked inside a synchronous decode — exactly how the phase
/// heartbeat caught the original wedge.
actor DecodeWatchdog {
    private let deadline: Duration
    private let abortGrace: Duration
    private let logger: Logger

    private var token: AbortToken?
    private var stream = ""
    private var startedAt: ContinuousClock.Instant?
    private var abortSignalledAt: ContinuousClock.Instant?
    private var poller: Task<Void, Never>?

    init(deadline: Duration, abortGrace: Duration, logger: Logger) {
        self.deadline = deadline
        self.abortGrace = abortGrace
        self.logger = logger
    }

    /// Arm the watchdog for one decode.
    func beginDecode(token: AbortToken, stream: String) {
        self.token = token
        self.stream = stream
        self.startedAt = .now
        self.abortSignalledAt = nil
        poller?.cancel()
        poller = Task { [weak self] in await self?.poll() }
    }

    /// Disarm after the decode returns (aborted or not).
    func endDecode() {
        poller?.cancel()
        poller = nil
        token = nil
        startedAt = nil
        abortSignalledAt = nil
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard let startedAt else { return }
            let age = ContinuousClock.now - startedAt
            if abortSignalledAt == nil, age >= deadline {
                token?.cancel()
                abortSignalledAt = .now
                logger.warning("whisper decode exceeded deadline; aborting stream=\(stream)")
            }
            if let sig = abortSignalledAt {
                let sinceAbort = ContinuousClock.now - sig
                if sinceAbort >= abortGrace {
                    let ms = Int(sinceAbort.components.seconds) * 1000
                        + Int(sinceAbort.components.attoseconds / 1_000_000_000_000_000)
                    logger.warning("whisper decode did not honor abort; age=\(ms)ms past abort signal, stream=\(stream)")
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the watchdog tests to verify they pass**

Run: `swift test --filter DecodeWatchdog` → Expected: PASS (3 tests).

- [ ] **Step 5: Thread `abort:` through `StreamingTranscriber`**

In `StreamingTranscriber.swift`:
- `ingest` (line 157): add `abort: AbortToken? = nil` param; pass it to `drainWindows`.
- `drainWindows` (line 192): add `abort: AbortToken?` param; pass to `runWindow`.
- `finish` (line 168): no abort (end-of-stream flush is bounded by the worker-drain timeout, not the per-decode watchdog).
- `runWindow` (line 224): add `abort: AbortToken?` param; pass to the `transcribeWindow` call (line 241):
  ```swift
  result = try transcriber.transcribeWindow(
      window, windowStart: windowStart, options: configuration.whisperOptions, abort: abort)
  ```

- [ ] **Step 6: Arm the watchdog per decode in the worker**

In `LiveRunner.run`, create the watchdog before the worker:

```swift
let watchdog = DecodeWatchdog(
    deadline: decodeDeadline, abortGrace: abortGrace, logger: logger)
```

In the worker's `drainReady`, wrap each `streamer.ingest(...)` call so a token is armed for it:

```swift
        while let frame = queue.tryDequeueNonSuspending() {
            let elapsed = ContinuousClock.now - elapsedFrom
            let token = AbortToken()
            await watchdog.beginDecode(token: token, stream: isMic ? "mic" : "system")
            let utterances = streamer.ingest(
                frame: frame, realTimeElapsed: elapsed, abort: token)
            await watchdog.endDecode()
            for utt in utterances { /* …existing sink append… */ }
        }
```

Add two init params to `LiveRunner`: `decodeDeadline: Duration = .seconds(10)` and `abortGrace: Duration = .seconds(5)` (stored + assigned alongside the others).

> The watchdog wraps the whole `ingest` call. Most ingests decode 0 windows
> (just buffer-append) and return instantly — the watchdog never fires. An
> ingest that runs a window and hangs gets aborted at the deadline.

- [ ] **Step 7: Write + run the watchdog end-to-end test**

Add to `LiveRunnerResilienceTests.swift` — the `BlockingWindowTranscriber` already honors the token (it loops `while abort?.isCancelled != true`), so with the watchdog armed it now *unblocks*:

```swift
    @Test("the watchdog aborts a hung decode and the worker keeps going")
    func watchdogAbortsHungDecodeAndResumes() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let liveURL = folder.appendingPathComponent(RecordingFolder.FileName.live)

        // First decode hangs until aborted; subsequent decodes return text.
        let flaky = HangThenRecoverTranscriber(hangCount: 1)
        let source = ControllableSource()
        let (runner, writer, _) = makeRunner(
            folder: folder, decodeDeadline: .milliseconds(150),
            abortGrace: .seconds(10))
        try await writer.start()

        let runTask = Task {
            try await runner.run(
                systemTranscriber: flaky, micTranscriber: nil,
                systemSource: source, micSource: nil, liveDiarizer: nil)
        }
        // Enough frames to trigger several decodes.
        for i in 0..<400 { await source.yieldFrame(.silence(sequenceIndex: i)) }
        try await Task.sleep(for: .milliseconds(800))
        await source.finish()
        let out = try await runTask.value
        await writer.finish()

        // The first window was aborted, later windows committed text → the
        // worker recovered rather than dying on the hang.
        #expect(out.utteranceLines > 0)
        #expect(await flaky.decodesAttempted >= 2)
        _ = liveURL
    }
```

Add the double:

```swift
/// Hangs (honoring the abort token) for its first `hangCount` decodes, then
/// returns a real-looking utterance — a decode that wedges once then recovers.
actor HangThenRecoverTranscriberBox { var attempted = 0 }
final class HangThenRecoverTranscriber: WindowTranscribing, @unchecked Sendable {
    private let box = HangThenRecoverTranscriberBox()
    private let hangCount: Int
    private let lock = NSLock(); private var _attempted = 0
    init(hangCount: Int) { self.hangCount = hangCount }
    var decodesAttempted: Int { get async { lock.withLock { _attempted } } }
    func transcribeWindow(
        _ samples: [Float], windowStart: Duration,
        options: WhisperTranscriber.Options, abort: AbortToken?
    ) throws -> TranscriptionResult {
        let n = lock.withLock { _attempted += 1; return _attempted }
        if n <= hangCount {
            while abort?.isCancelled != true { Thread.sleep(forTimeInterval: 0.02) }
            throw WhisperTranscriber.TranscribeError.transcriptionFailed(-999)
        }
        return TranscriptionResult(
            segments: [TranscriptSegment(start: windowStart, end: windowStart, text: "ok")],
            language: "en")
    }
}
```

> Make `decodesAttempted` a simple lock-read (drop the unused `box` actor if it
> trips the build — it is only there to satisfy `async` access; a lock read is
> enough). Keep whichever compiles cleanly.

Run: `swift build` → Expected: `Build complete!`
Run: `swift test --filter LiveRunner` → Expected: PASS (all prior + the new watchdog test).
Run: `swift test --filter Streaming` → Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/PulsarTraceEngine/Streaming/DecodeWatchdog.swift Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift Sources/PulsarTraceEngine/Streaming/LiveRunner.swift Tests/UnitTests/DecodeWatchdogTests.swift Tests/PipelineTests/LiveRunnerResilienceTests.swift
git commit -m "feat: per-decode abort-watchdog so a hung whisper window recovers (Phase 2)"
```

---

## Task 6: Verify the unrecoverable-hang monitor end-to-end

The monitor logic already lives in `DecodeWatchdog` (Task 5, Step 3) and is unit-tested (`warnsWhenAbortNotHonored`). This task confirms it fires in the integrated worker when a decode genuinely ignores the abort.

**Files:**
- Test: `Tests/PipelineTests/LiveRunnerResilienceTests.swift`

- [ ] **Step 1: Write the failing integration test**

Add to `LiveRunnerResilienceTests.swift` — a transcriber that ignores the abort token entirely (the true GPU-hang analogue), plus a runner whose logger is captured:

```swift
    @Test("a decode that ignores the abort is monitored with an escalating warning")
    func unrecoverableHangIsMonitored() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let capture = CaptureLog()
        let ignorer = IgnoresAbortTranscriber()
        let source = ControllableSource()
        let (runner, writer, _) = makeRunner(
            folder: folder, logger: Logger(label: "test") { _ in capture },
            decodeDeadline: .milliseconds(100), abortGrace: .milliseconds(150),
            workerDrainTimeout: .milliseconds(300))
        try await writer.start()

        let runTask = Task {
            try await runner.run(
                systemTranscriber: ignorer, micTranscriber: nil,
                systemSource: source, micSource: nil, liveDiarizer: nil)
        }
        for i in 0..<200 { await source.yieldFrame(.silence(sequenceIndex: i)) }
        try await Task.sleep(for: .milliseconds(800))
        await source.finish()
        _ = await withTimeoutOrNil(seconds: 5) { try await runTask.value }
        await writer.finish()
        ignorer.release()   // let the abandoned decode thread exit

        let warnings = capture.messages.filter { $0.contains("did not honor abort") }
        #expect(!warnings.isEmpty, "monitor did not warn; got \(capture.messages)")
    }
```

Add the double + a `CaptureLog` handler (or reuse one) to the doubles section:

```swift
/// Ignores the abort token completely — the true single-kernel GPU-hang
/// analogue: nothing the watchdog does interrupts it. Released explicitly by
/// the test so the abandoned thread can exit.
final class IgnoresAbortTranscriber: WindowTranscribing, @unchecked Sendable {
    private let lock = NSLock(); private var released = false
    func release() { lock.withLock { released = true } }
    func transcribeWindow(
        _ samples: [Float], windowStart: Duration,
        options: WhisperTranscriber.Options, abort: AbortToken?
    ) throws -> TranscriptionResult {
        while !(lock.withLock { released }) { Thread.sleep(forTimeInterval: 0.02) }
        return TranscriptionResult(segments: [], language: "en")
    }
}

final class CaptureLog: LogHandler, @unchecked Sendable {
    private let lock = NSLock(); private var _m: [String] = []
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey k: String) -> Logger.Metadata.Value? {
        get { metadata[k] } set { metadata[k] = newValue } }
    var messages: [String] { lock.withLock { _m } }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        lock.withLock { _m.append("\(message)") }
    }
}
```

Add a `logger:` param to the test `makeRunner` helper (default `Logger(label: "test")`) and the `workerDrainTimeout:`, `decodeDeadline:`, `abortGrace:` params, all forwarded to `LiveRunner(...)`.

- [ ] **Step 2: Run it to verify it fails, then passes**

Run: `swift test --filter LiveRunner` → Expected: FAIL only if the monitor wiring is not reached (e.g., the worker `endDecode` runs before grace). It should PASS given Task 5's `DecodeWatchdog` — if it fails, confirm the worker arms `beginDecode` *before* the synchronous ingest and only calls `endDecode` *after* it returns (so the grace timer runs during the hang).

> Because the ignored decode never returns, the worker stays in `ingest` and
> `endDecode` is never reached during the hang — the watchdog's poller keeps
> running and emits the escalating warning. The run still returns via the
> `workerDrainTimeout` race from Task 4 Step 5.

- [ ] **Step 3: Commit**

```bash
git add Tests/PipelineTests/LiveRunnerResilienceTests.swift
git commit -m "test: monitor fires an escalating warning when a decode ignores abort"
```

---

## Task 7: Full verification + docs sync

- [ ] **Step 1: Run every relevant narrow filter** (all bare, `dangerouslyDisableSandbox: true`)

```
swift test --filter UnitTests
swift test --filter LiveRunner
swift test --filter Streaming
swift test --filter Transcription
swift test --filter WhisperAbort
swift test --filter DiarizationE2E
swift test --filter Refinement
```
Expected: every command green. If any test outside this change is red, treat it per CLAUDE.md (fix or explicitly gate — no red suite); do not hand-wave "unrelated".

- [ ] **Step 2: Confirm the diagnostic phase-tracker still reflects reality**

The drain still sets phases (`wav-append-*`, `enqueue-*`, the silence-watchdog phases). The old `whisper-ingest-*` / `await-sink-append*Utterance` phases now live on the worker, which is *not* tracked by `LiveRunnerPhaseTracker` (the tracker watches the drain loop). That is correct: the drain can no longer wedge on whisper, and the worker hang is covered by `DecodeWatchdog`. No code change — just verify the heartbeat test still passes:

```
swift test --filter LiveRunnerPhaseTracker
```
Expected: PASS.

- [ ] **Step 3: Update docs** (per pulsartrace-doc-sync; do not invoke other skills here)

- Mark `docs/specs/2026-05-22-refine-perf-and-capture-resilience-plan.md`'s "Out of scope" engine-wedge note as resolved by this work (one line + link to the design doc).
- If `project-docs/DECISIONS.md` records the live-pass concurrency model, add a short entry: the live run loop is now a recording-safe drain + a bounded-queue whisper worker with an abort-watchdog; recording is decoupled from transcription.
- Update any component doc that describes `LiveRunner` as a single per-frame loop.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: record live-pipeline decoupling; resolve engine-wedge open item"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** G1 recording safety → Task 4 (drain/queue split, WAV-first) + recording-safety test. G2 bounded memory → Task 3 (capacity) + drop test. G3 hang recovery → Task 5 (watchdog + abort). G4 visible drops → Task 4 (drop note). Real-abort proof → Task 2. Unrecoverable-hang monitor → Tasks 5–6. `WindowTranscribing` seam → Task 1. `max_tokens` cap → Task 2. Per-stream queues + single worker → Tasks 3–4. Invariant #7 (no paths) → checked in every new log line. All design §3 success criteria map to a test.
- **Type consistency:** `transcribeWindow(_:windowStart:options:abort:)` is the one signature used by the protocol (Task 1), `WhisperTranscriber` (Tasks 1–2), `StreamingTranscriber.runWindow` (Task 5), and all stubs. `AbortToken.cancel()`/`.isCancelled`, `BoundedFrameQueue.enqueue/dequeue/tryDequeueNonSuspending/finish/isFinishedAndEmpty/consumeDropEpisodeStarted/consumeCaughtUp`, and `DecodeWatchdog.beginDecode(token:stream:)/endDecode()` are used consistently across tasks and tests.
- **Known implementer judgment calls (flagged inline, not placeholders):** (a) Sendable capture of the non-`Sendable` streamers into the worker `Task` — resolve with an `@unchecked Sendable` box if the compiler objects (Task 4 Step 6); (b) the `BoundedFrameQueue` direct-hand-off scratch field may need folding into the `withLock` return (Task 3 Step 3); (c) the exact `max_tokens` value is set to 256 and validated by `capDoesNotTruncateNormalSpeech`, with final tuning left to design §12. These are concrete code decisions with a stated resolution, not open requirements.
