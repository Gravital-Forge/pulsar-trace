# Refine perf & capture resilience implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four shipped-but-broken items uncovered while diagnosing recording `2026-05-20-113001` (17-min cutoff) and `2026-05-20-100033` ("io" refinement failure): reuse one `WhisperTranscriber` per refinement job instead of one per region (the biggest user-visible perf win), persist the underlying error of a failed refinement so the next failure is debuggable, wire the existing `SCStream` error callback into the capture-restart path, and add cross-process locking to the events log so concurrent appends from `pulsartrace-mac` and `pulsartrace-capture` stop clobbering each other.

**Architecture:** All four are narrow, surgical fixes — no new components, no schema breaks. Task 1 introduces a small `SharedTranscriber` wrapper so the refiner's existing `transcribe:` closure can lazily reuse one model instance per job without changing `ResumableRefiner`'s public API (so existing tests stand). Task 2 adds an optional `lastError` field to the existing `refine-progress.json` schema (backward-compatible via Swift's synthesised Optional decoding). Task 3 assigns the already-defined `onStreamError` callback in `DeviceCaptureSource.makeSystemEngine` so an `SCStream` error routes into the existing `handleStall` machinery. Task 4 wraps `EventWriter.append` with `flock(LOCK_EX)` on the file descriptor so two processes appending to `events/YYYY-MM-DD.jsonl` can no longer interleave bytes.

**Tech Stack:** Swift 6.2 (`@unchecked Sendable` wrapper for the non-Sendable `WhisperTranscriber`), Foundation `FileHandle.fileDescriptor` + Darwin `flock(2)` (`LOCK_EX`/`LOCK_UN`), Swift Testing. No new dependencies.

---

## Background

Three live observations from the user, traced through the code in this session:

1. **Recording 2026-05-20-113001 stopped capturing audio at ~17:48 of wall time but `recording_stopped` event reports `duration_seconds: 1441` (24:01).** No `recording_paused`/`recording_resumed` events for that session. Capture-side gap: `SystemAudioCaptureEngine.onStreamError` (`Sources/PulsarTraceCapture/SystemAudioCaptureEngine.swift:48`) is declared and fired (line 147) but never assigned anywhere in the repo — an `SCStream.didStopWithError` is a no-op.
2. **Whisper region refinement is far slower than realtime.** `refine-progress.json` for session 100033 shows 65 regions completed across ~85 minutes — ~78s/region wall time. Root cause: `RefinementJobQueue.makeStandard`'s `transcribe:` closure (`Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:295-298`) builds a fresh `WhisperTranscriber` per region, so `whisper_init_from_file_with_params` (Metal pipeline state object setup, KV-cache, GGML backend) runs on every region. The OfflineRefiner CLI path is correct (one transcriber per stream); the queue path is not. D36 promoted this to a decision based on incorrect facts ("matches OfflineRefiner" — it doesn't; "tens of ms overhead" — it's multi-second for `large-v3` on Metal).
3. **Session 100033 refinement failed with `errorClass: "io"`.** That's the catch-all in `RefinementJobQueue.runNext` — the underlying error was dropped before logging. Even after the typed `RefinementJobError.classify` lands in commit `434e57d`, the raw error description is still nowhere in logs or on disk, so when classify picks the wrong bucket you have nothing to debug from.
4. **Bonus discovery from inspecting `events/2026-05-20.jsonl`:** a corrupted line where a `recording_paused` event from the capture daemon was clobbered mid-write by an `app_stopped` event from the menubar app. `EventWriter` is an `actor` (serialises within a process) but `pulsartrace-capture` and `pulsartrace-mac` are separate processes appending to the same daily file with no cross-process lock.

---

## File Structure

### New files

```
Sources/PulsarTraceEngine/Refinement/Jobs/
  SharedTranscriber.swift           // Per-job lazy WhisperTranscriber wrapper.
                                    // @unchecked Sendable; NSLock around a stored
                                    // optional that is built on first .get() and
                                    // returned for every subsequent .get().

Tests/UnitTests/
  SharedTranscriberTests.swift      // get() returns the same instance across calls;
                                    // first .get() builds, later .get() does not.
                                    // Uses a stub factory rather than a real model
                                    // file so the test stays in UnitTests.
  EventWriterFileLockTests.swift    // Holding flock(LOCK_EX) on a foreign fd to the
                                    // same events file blocks EventWriter.append
                                    // until the lock is released.
```

### Modified files

```
Sources/PulsarTraceEngine/Events/EventWriter.swift
  // append() acquires flock(LOCK_EX) on the file's fd before write and releases
  // it after, so two processes both writing via EventWriter cannot interleave
  // partial JSONL lines. Imports Darwin for flock / LOCK_EX / LOCK_UN.

Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
  // runJob captures one SharedTranscriber per job and passes its .get() into the
  // ResumableRefiner's transcribe: closure. Doc-comment block above the closure
  // updated to describe the new pattern instead of the (now-reopened) D36 rationale.

Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift
  // Adds optional public var lastError: String? — Codable handles missing keys
  // for Optional, so old refine-progress.json files still decode. Encoder
  // emits the key only when non-nil (default behaviour for Optional).

Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift
  // run(job:) wraps its body in a try-catch that writes the error's description
  // (with filesystem-path redaction) into progress.lastError, persists it, and
  // re-throws. Stale "B4 — happy-path stage iteration only" block comment at
  // lines 14-16 deleted.

Sources/PulsarTraceEngine/Refinement/Jobs/Cancellable.swift
  // Stale "(B7)" phase marker in the doc comment removed.

Sources/PulsarTraceCapture/DeviceCaptureSource.swift
  // makeSystemEngine() assigns engine.onStreamError to a closure that logs the
  // error type and routes into handleStall(stream: .system). The closure category
  // redaction in handleStall's logging path already covers Hard Invariant #7.

project-docs/DECISIONS.md
  // D36 rewritten — the original rationale is wrong on its facts ("matches
  // OfflineRefiner" — does not; "tens of ms" — multi-second on Metal). New text
  // records the corrected decision: one transcriber per job, via SharedTranscriber.
  // New D37 records the EventWriter cross-process flock.

project-docs/PLAN.md
  // The "Branch close-out" bullet at line 395 gets a follow-up note pointing to
  // this plan, since the D36 "decision" is being reopened and the capture-side
  // wiring gap was never recorded.

docs/events-schema.md
  // Brief note that EventWriter holds an advisory exclusive lock per append, so
  // an external consumer reading the file mid-append should expect to retry.
```

---

## Decisions baked into the tasks

- **D-RP1 — Hold the per-job transcriber across pauses.** When `pauseForRecording` closes the gate, `SharedTranscriber` keeps the `WhisperTranscriber` alive (~3 GB for `large-v3`). A long recording paused for hours holds that memory. The alternative — `SharedTranscriber.drop()` on pause, rebuild on resume — costs a model reload per pause cycle, which defeats the perf fix for short pauses (the common case: a stall recovery that resumes in seconds). v1 accepts the held memory; if it becomes a real issue, a separate change can add a drop-after-N-seconds heuristic.
- **D-RP2 — `lastError` carries a redacted description, not a stack trace.** The string is `"\(type(of: error)): \(error)"` with any occurrence of the recording folder path replaced by `<folder>`. Stack traces / file/line info would need `Thread.callStackSymbols`, which is noisy and would balloon the JSON. The description is enough to disambiguate `DiarizeError.timedOut` from `DiarizeError.nonZeroExit(127)`, which is what's missing today.
- **D-RP3 — Test the flock invariant via a foreign fd in the same process, not a subprocess.** Spawning a subprocess just for this test is heavy and brittle (the harness already has cross-suite parallelism races, per `CLAUDE.md`). A single-process test that opens a second `FileHandle` and acquires its own `flock(LOCK_EX)` is enough to prove `EventWriter` honours the lock — which is what we need for two processes both using `EventWriter` to be safe.
- **D-RP4 — Route `onStreamError` into `handleStall`, not a new dedicated handler.** `handleStall` already does the right thing: emit `recording_paused` (reason `stall_recovery`), stop the engine, build a fresh one with backoff. An `SCStream` error means the stream is dead in the same shape a silent stall does — single restart path is enough and avoids parallel state machines.

---

## Task 1: One `WhisperTranscriber` per job

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift`
- Create: `Tests/UnitTests/SharedTranscriberTests.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:289-298`

### Step 1.1: Write the failing test for `SharedTranscriber`

- [ ] **Step 1.1.1: Create the test file**

Create `Tests/UnitTests/SharedTranscriberTests.swift`:

```swift
// Tests/UnitTests/SharedTranscriberTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("SharedTranscriber")
struct SharedTranscriberTests {

    /// A bare object with reference identity so the test can check that two
    /// `.get()` calls return the same instance without depending on a real
    /// `WhisperTranscriber` (which needs an on-disk model).
    private final class Sentinel: @unchecked Sendable {
        let id = UUID()
    }

    @Test("first get() invokes the factory; later get()s do not")
    func factoryRunsOnce() throws {
        let counter = Counter()
        let shared = SharedTranscriberBox<Sentinel> {
            counter.bump()
            return Sentinel()
        }
        let a = try shared.get()
        let b = try shared.get()
        let c = try shared.get()
        #expect(a.id == b.id)
        #expect(b.id == c.id)
        #expect(counter.value == 1, "factory must run exactly once")
    }

    @Test("a thrown factory error propagates and is retried on the next get()")
    func factoryRetriesAfterThrow() throws {
        struct Boom: Error {}
        let counter = Counter()
        let shared = SharedTranscriberBox<Sentinel> {
            counter.bump()
            if counter.value == 1 { throw Boom() }
            return Sentinel()
        }
        #expect(throws: Boom.self) { _ = try shared.get() }
        let ok = try shared.get()
        _ = ok
        #expect(counter.value == 2, "first get threw, second get re-ran the factory")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}
```

- [ ] **Step 1.1.2: Run the test — must fail**

Run with `dangerouslyDisableSandbox: true`:
```
swift test --filter SharedTranscriber
```
Expected: compile error / "cannot find 'SharedTranscriberBox' in scope".

### Step 1.2: Implement `SharedTranscriberBox`

- [ ] **Step 1.2.1: Create the source file**

Create `Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift`:

```swift
// Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift
import Foundation

/// Holds at most one `T` for the lifetime of the box; `get()` builds the
/// instance lazily on the first call and returns the same instance for every
/// later call.
///
/// Used by `RefinementJobQueue.makeStandard` to reuse one `WhisperTranscriber`
/// across every VAD region of a refinement job (D36, reopened) — building a
/// fresh `WhisperTranscriber` per region was the dominant cost of a
/// refinement pass on Apple Silicon because `whisper_init_from_file_with_params`
/// rebuilds the Metal pipeline state on every call.
///
/// Generic over `T` rather than hard-coded to `WhisperTranscriber` so the
/// type can be tested without an on-disk model file.
public final class SharedTranscriberBox<T>: @unchecked Sendable {

    private let factory: () throws -> T
    private let lock = NSLock()
    private var cached: T?

    public init(_ factory: @escaping () throws -> T) {
        self.factory = factory
    }

    /// Return the cached instance, building it on the first call. A factory
    /// throw on the first call is propagated and leaves the cache empty, so a
    /// retry on the next `get()` re-runs the factory.
    public func get() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let made = try factory()
        cached = made
        return made
    }
}
```

- [ ] **Step 1.2.2: Run the test — must pass**

```
swift test --filter SharedTranscriber
```
Expected: 2/2 pass.

- [ ] **Step 1.2.3: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift \
        Tests/UnitTests/SharedTranscriberTests.swift
git commit -m "$(cat <<'EOF'
feat(refine): SharedTranscriberBox holds one instance per job

Lazy single-instance wrapper that builds on the first get() and returns
the same instance for every later call. Generic over T so it can be unit-
tested without an on-disk Whisper model. Used by the queue's makeStandard
path in the next commit to stop rebuilding WhisperTranscriber per region.
EOF
)"
```

### Step 1.3: Wire `SharedTranscriberBox` into `RefinementJobQueue.makeStandard`

- [ ] **Step 1.3.1: Edit `RefinementJobQueue.swift`**

Replace lines 289-298 of `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift`:

Current:
```swift
            // WhisperTranscriber is NOT Sendable (whisper_context is not
            // thread-safe). Creating a new instance per-region is the accepted
            // project pattern — OfflineRefiner uses a transcriberFactory for
            // the same reason. The model file is mmapped by whisper.cpp so the
            // OS page-cache amortises the cost across calls.
            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try WhisperTranscriber(modelURL: modelURL)
                    return try t.transcribeRegion(samples, region: region, options: options)
                },
```

New:
```swift
            // One WhisperTranscriber per *job*, not per region. `whisper_init_
            // from_file_with_params` rebuilds the Metal pipeline state object
            // on every call — multi-second on Apple Silicon for `large-v3` —
            // so per-region construction was the dominant cost of a refinement
            // pass (DECISIONS.md D36, reopened). The transcriber is non-
            // `Sendable` (it wraps `whisper_context`, which is not thread-safe),
            // so the `SharedTranscriberBox` lock + the `metalLock` inside
            // `WhisperTranscriber` together serialise every touch; the queue's
            // single-worker invariant means there is never more than one job's
            // box alive at once.
            let sharedTranscriber = SharedTranscriberBox {
                try WhisperTranscriber(modelURL: modelURL)
            }
            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try sharedTranscriber.get()
                    return try t.transcribeRegion(samples, region: region, options: options)
                },
```

- [ ] **Step 1.3.2: Verify existing queue tests still pass**

```
swift test --filter RefinementJobQueue
```
Expected: all green (`RefinementJobQueueTests` — Pipeline; the production wiring change is type-checked and doesn't affect test behaviour because tests pass their own `runJob` directly).

- [ ] **Step 1.3.3: Verify ResumableRefiner tests still pass**

```
swift test --filter ResumableRefiner
```
Expected: 4/4 pass — `ResumableRefiner`'s public API didn't change.

- [ ] **Step 1.3.4: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
git commit -m "$(cat <<'EOF'
fix(refine): reuse one WhisperTranscriber per job, not per region

RefinementJobQueue.makeStandard's transcribe: closure built a fresh
WhisperTranscriber on every region, which rebuilds the Metal pipeline
state via whisper_init_from_file_with_params each time — multi-second
on Apple Silicon for large-v3. Per-region construction added up to
roughly 80 seconds per region on a recent session (130+ regions).

The closure now closes over a SharedTranscriberBox that builds one
WhisperTranscriber on its first .get() and returns the same instance
for every later region in the same job. metalLock inside
WhisperTranscriber + the queue's single-worker invariant keep the
contract from D8 intact.

Reopens DECISIONS.md D36 — original rationale was factually wrong
about both the OfflineRefiner pattern and the per-call init cost.
EOF
)"
```

---

## Task 2: Persist the real error of a failed refinement

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`
- Modify: `Tests/UnitTests/RefinementProgressTests.swift`
- Modify: `Tests/UnitTests/ResumableRefinerTests.swift`

### Step 2.1: Add `lastError` to `RefinementProgress`

- [ ] **Step 2.1.1: Write the failing test**

Append to `Tests/UnitTests/RefinementProgressTests.swift`:

```swift
    @Test("lastError round-trips through JSON when set")
    func lastErrorRoundTrips() throws {
        var p = RefinementProgress.empty(jobId: "j", recordingId: "r")
        p.lastError = "DiarizeError.timedOut after 600s"
        let data = try p.encoded()
        let back = try RefinementProgress.decode(data)
        #expect(back.lastError == "DiarizeError.timedOut after 600s")
    }

    @Test("lastError is omitted from JSON when nil; old files still decode")
    func lastErrorOptional() throws {
        let p = RefinementProgress.empty(jobId: "j", recordingId: "r")
        let data = try p.encoded()
        // The key must not be present when the value is nil.
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("last_error"))
        // Decoding a payload without the key (mimicking a pre-existing file)
        // succeeds with lastError == nil.
        let back = try RefinementProgress.decode(data)
        #expect(back.lastError == nil)
    }
```

- [ ] **Step 2.1.2: Run — must fail**

```
swift test --filter RefinementProgress
```
Expected: compile error on `p.lastError = ...` ("value of type 'RefinementProgress' has no member 'lastError'").

- [ ] **Step 2.1.3: Add the field**

Edit `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift`. Add the property right after `lastCheckpointAt`:

```swift
    public var lastCheckpointAt: Date

    /// Description of the most recent error that caused this job to fail or
    /// abort, with filesystem paths redacted. `nil` on a healthy job. Persists
    /// across a retry so the next user / debugger has something concrete to
    /// look at — `RefinementJobState.failed.errorClass` is a coarse bucket.
    public var lastError: String?
```

Update the `init` to take it (defaulted to nil so call sites stay terse):

Current end of init parameters:
```swift
        language: String?,
        lastCheckpointAt: Date
    ) {
```

New:
```swift
        language: String?,
        lastCheckpointAt: Date,
        lastError: String? = nil
    ) {
```

Add the assignment at the end of the init body:
```swift
        self.lastCheckpointAt = lastCheckpointAt
        self.lastError = lastError
```

Update the `empty` factory (no change needed — `lastError` defaults to nil) — verify it still compiles.

Add the new key to the manual `CodingKeys` enum at line 134-147. After `case lastCheckpointAt = "last_checkpoint_at"`, add:

```swift
        case lastError = "last_error"
```

`encoded()` uses `JSONEncoder` without `keyEncodingStrategy`, so the manual CodingKeys mapping is what makes `lastError` serialise as `last_error`. `JSONEncoder` omits `nil` Optionals by default, which is why the "key absent when nil" test above passes without further code.

- [ ] **Step 2.1.4: Run — must pass**

```
swift test --filter RefinementProgress
```
Expected: all green, including the two new tests.

- [ ] **Step 2.1.5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift \
        Tests/UnitTests/RefinementProgressTests.swift
git commit -m "$(cat <<'EOF'
feat(refine): add optional lastError to RefinementProgress

Optional String field on the on-disk progress checkpoint. Old refine-
progress.json files still decode (Codable Optional handles missing keys);
new encodes omit the key when nil. The next commit writes a redacted
error description here when ResumableRefiner.run throws, so a failed
job leaves something concrete behind instead of just the coarse
errorClass bucket in the queue state file.
EOF
)"
```

### Step 2.2: Have `ResumableRefiner.run` write `lastError` on failure

- [ ] **Step 2.2.1: Write the failing test**

Append to `Tests/UnitTests/ResumableRefinerTests.swift`:

```swift
    @Test("a thrown error is recorded in refine-progress.json as lastError")
    func failureWritesLastError() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        struct Boom: Error, CustomStringConvertible {
            var description: String { "synthetic transcribe failure" }
        }

        let refiner = ResumableRefiner(
            transcribe: { _, _, _ in throw Boom() },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                fatalError("diarize should not be reached when transcribe throws")
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_e", recordingId: "rec_e", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)

        await #expect(throws: Boom.self) {
            try await refiner.run(job: job)
        }

        let progressURL = folder.appendingPathComponent("refine-progress.json")
        let data = try Data(contentsOf: progressURL)
        let progress = try RefinementProgress.decode(data)
        let recorded = try #require(progress.lastError)
        #expect(recorded.contains("synthetic transcribe failure"),
                "lastError should carry the underlying description")
        #expect(!recorded.contains(folder.path),
                "filesystem path must be redacted")
    }
```

- [ ] **Step 2.2.2: Run — must fail**

```
swift test --filter ResumableRefiner
```
Expected: the new test fails ("progress.lastError is nil"). Existing 4 tests still pass.

- [ ] **Step 2.2.3: Wrap `run(job:)` and add the redacted-description helper**

Edit `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift`.

Replace the body of `public func run(job:)` (currently lines 59-80). The current body has 8 stage advances and stage methods called in sequence. Wrap them with a try/catch that persists `lastError`:

Current:
```swift
    public func run(job: RefinementJob) async throws {
        let folder = try RecordingFolder.resolve(inputPath: job.folderURL)
        var progress = loadOrInitProgress(folder: folder, job: job)

        try await advance(&progress, to: .resolvingInput, folder: folder)

        try await advance(&progress, to: .transcribingSystem, folder: folder)
        try await transcribeSystemStream(folder: folder, progress: &progress)

        try await advance(&progress, to: .diarizing, folder: folder)
        let diarization = try await runDiarization(folder: folder, progress: &progress)

        try await advance(&progress, to: .transcribingMic, folder: folder)
        if folder.micStream != nil {
            try await transcribeMicStream(folder: folder, progress: &progress)
        }

        try await advance(&progress, to: .merging, folder: folder)
        try await advance(&progress, to: .writingFinal, folder: folder)
        try await advance(&progress, to: .writingMetadata, folder: folder)
        try mergeAndWrite(folder: folder, progress: progress, diarization: diarization, job: job)
    }
```

New:
```swift
    public func run(job: RefinementJob) async throws {
        let folder = try RecordingFolder.resolve(inputPath: job.folderURL)
        var progress = loadOrInitProgress(folder: folder, job: job)
        // Clear any prior lastError on a fresh start — a healthy completion
        // should not leave the previous failure's text behind.
        if progress.lastError != nil {
            progress.lastError = nil
            try? persist(progress, folder: folder)
        }

        do {
            try await advance(&progress, to: .resolvingInput, folder: folder)

            try await advance(&progress, to: .transcribingSystem, folder: folder)
            try await transcribeSystemStream(folder: folder, progress: &progress)

            try await advance(&progress, to: .diarizing, folder: folder)
            let diarization = try await runDiarization(folder: folder, progress: &progress)

            try await advance(&progress, to: .transcribingMic, folder: folder)
            if folder.micStream != nil {
                try await transcribeMicStream(folder: folder, progress: &progress)
            }

            try await advance(&progress, to: .merging, folder: folder)
            try await advance(&progress, to: .writingFinal, folder: folder)
            try await advance(&progress, to: .writingMetadata, folder: folder)
            try mergeAndWrite(folder: folder, progress: progress, diarization: diarization, job: job)
        } catch {
            progress.lastError = Self.redactPath(
                "\(type(of: error)): \(error)",
                folder: folder.directory)
            try? persist(progress, folder: folder)
            logger.warning("refinement job \(job.id) failed: \(progress.lastError ?? "?")")
            throw error
        }
    }

    /// Replace any occurrence of `folder`'s path in `s` with `<folder>` so the
    /// redacted text is safe to put in the progress file even if the underlying
    /// error rendered a filesystem path (Hard Invariant #7).
    static func redactPath(_ s: String, folder: URL) -> String {
        s.replacingOccurrences(of: folder.path, with: "<folder>")
    }
```

- [ ] **Step 2.2.4: Run — must pass**

```
swift test --filter ResumableRefiner
```
Expected: 5/5 pass.

- [ ] **Step 2.2.5: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift \
        Tests/UnitTests/ResumableRefinerTests.swift
git commit -m "$(cat <<'EOF'
fix(refine): write redacted error description to refine-progress.json on failure

ResumableRefiner.run wraps its stage iteration in try/catch and writes
"\(type(of: error)): \(error)" to RefinementProgress.lastError before
re-throwing, after replacing the recording-folder path with <folder>.
A successful start also clears any prior lastError.

The queue's coarse errorClass bucket (RefinementJobError.classify) alone
left a failed job with nothing concrete to debug from; lastError preserves
the underlying error text in a place the next retry / user / agent can
read. logger.warning mirrors the same string to stderr so a live debug
session can see it without opening the JSON file.
EOF
)"
```

---

## Task 3: Wire `onStreamError` in `DeviceCaptureSource.makeSystemEngine`

**Files:**
- Modify: `Sources/PulsarTraceCapture/DeviceCaptureSource.swift:189-193`
- Modify: `Tests/CaptureTests/StallRecoveryTests.swift`

### Step 3.1: Write the failing test

- [ ] **Step 3.1.1: Append a test asserting the engine's `onStreamError` is non-nil**

`SystemAudioCaptureEngine` already fires `onStreamError?` when its delegate method `stream(_:didStopWithError:)` is called (verified in existing engine code, line 147). The gap is purely in `DeviceCaptureSource.makeSystemEngine`, which never assigns the callback. The smallest test that proves the wiring is to construct the engine via `makeSystemEngine()` and assert the assignment is in place.

`makeSystemEngine()` is currently `private`. Promote it to `internal` so the test can call it directly (same approach as a similar `internal` carve-out elsewhere in this file).

Append to `Tests/CaptureTests/StallRecoveryTests.swift`:

```swift
    /// Regression for session 2026-05-20-113001 (~17-min cutoff with no
    /// `recording_paused` event): `SystemAudioCaptureEngine.onStreamError`
    /// was defined and fired by the delegate's `didStopWithError`, but
    /// `DeviceCaptureSource.makeSystemEngine` never assigned it, so an
    /// `SCStream` error was a silent no-op — no restart, no event.
    @Test("DeviceCaptureSource wires onStreamError so SCStream errors trigger restart")
    func systemEngineHasStreamErrorWiring() {
        let config = DeviceCaptureSource.Configuration(
            recordingId: "rec_wire_test",
            outputDirBasename: "wire",
            micDeviceID: nil,
            systemAudioEnabled: true,
            systemSocketPath: URL(fileURLWithPath: "/tmp/pt-wire-sys.sock"),
            micSocketPath: URL(fileURLWithPath: "/tmp/pt-wire-mic.sock"),
            modelLive: "base",
            events: nil)
        let source = DeviceCaptureSource(configuration: config)
        let engine = source.makeSystemEngine()
        #expect(engine.onStreamError != nil,
                "SCStream errors must be routed into the stall-restart path")
    }
```

- [ ] **Step 3.1.2: Run — must fail**

```
swift test --filter StallRecovery
```
Expected: compile error if `makeSystemEngine` is still `private`, or `#expect` failure (`engine.onStreamError != nil`) once it is `internal`.

### Step 3.2: Make `makeSystemEngine` internal and assign `onStreamError`

- [ ] **Step 3.2.1: Edit `DeviceCaptureSource.swift`**

Replace lines 182-194 of `Sources/PulsarTraceCapture/DeviceCaptureSource.swift`:

Current:
```swift
    // MARK: - Engine construction

    private func makeMicEngine() -> MicCaptureEngine {
        let engine = MicCaptureEngine(deviceID: configuration.micDeviceID)
        engine.onEvent = { [weak self] event in self?.route(event, .mic) }
        engine.onStall = { [weak self] in self?.handleStall(stream: .mic) }
        return engine
    }

    private func makeSystemEngine() -> SystemAudioCaptureEngine {
        let engine = SystemAudioCaptureEngine(filter: .allApps)
        engine.onEvent = { [weak self] event in self?.route(event, .system) }
        engine.onStall = { [weak self] in self?.handleStall(stream: .system) }
        return engine
    }
```

New:
```swift
    // MARK: - Engine construction

    // `internal` (not `private`) so `StallRecoveryTests` can construct the
    // engines via the production wiring path and assert that the watchdog /
    // stream-error callbacks are assigned. The tests don't start the engines —
    // they just inspect the closure slots.
    internal func makeMicEngine() -> MicCaptureEngine {
        let engine = MicCaptureEngine(deviceID: configuration.micDeviceID)
        engine.onEvent = { [weak self] event in self?.route(event, .mic) }
        engine.onStall = { [weak self] in self?.handleStall(stream: .mic) }
        return engine
    }

    internal func makeSystemEngine() -> SystemAudioCaptureEngine {
        let engine = SystemAudioCaptureEngine(filter: .allApps)
        engine.onEvent = { [weak self] event in self?.route(event, .system) }
        engine.onStall = { [weak self] in self?.handleStall(stream: .system) }
        // A hard `SCStream` failure (e.g. TCC revoked mid-session, display
        // rearrangement, ScreenCaptureKit internal abort) reaches
        // `SystemAudioCaptureEngine.stream(_:didStopWithError:)`, which fires
        // `onStreamError`. Without this assignment the callback fires into
        // the void and capture dies silently — observed on session
        // 2026-05-20-113001 (~17 min in, no `recording_paused` event).
        // Route into the same path as a silent stall: `handleStall` emits
        // `recording_paused` (reason `stall_recovery`), stops the engine,
        // and rebuilds a fresh one with exponential backoff. The error's
        // type name is logged for diagnosability (its description is not
        // logged because it can carry a filesystem path — Hard Invariant #7).
        engine.onStreamError = { [weak self] error in
            guard let self else { return }
            self.log("system audio stream error (\(type(of: error)))")
            self.handleStall(stream: .system)
        }
        return engine
    }
```

- [ ] **Step 3.2.2: Run — must pass**

```
swift test --filter StallRecovery
```
Expected: all green, including the new wiring test.

- [ ] **Step 3.2.3: Commit**

```bash
git add Sources/PulsarTraceCapture/DeviceCaptureSource.swift \
        Tests/CaptureTests/StallRecoveryTests.swift
git commit -m "$(cat <<'EOF'
fix(capture): wire SystemAudioCaptureEngine.onStreamError into stall restart

SystemAudioCaptureEngine defined and fired onStreamError from
stream(_:didStopWithError:), but DeviceCaptureSource.makeSystemEngine
never assigned it — an SCStream that aborted with an error was a silent
no-op (no recording_paused event, no restart, no log line). Session
2026-05-20-113001 stopped delivering audio at ~17 min with no observable
recovery attempt; this gap is the most plausible cause.

The new closure logs the error's *type name* only (Hard Invariant #7
forbids paths in logs) and routes into handleStall(stream: .system),
reusing the existing emit-paused / stop / rebuild-with-backoff machinery
already proven by the FrameWatchdog path.

makeMicEngine / makeSystemEngine promoted from private to internal so
StallRecoveryTests can assert the closure slots are populated.
EOF
)"
```

---

## Task 4: `flock` on `EventWriter.append`

**Files:**
- Modify: `Sources/PulsarTraceEngine/Events/EventWriter.swift`
- Create: `Tests/UnitTests/EventWriterFileLockTests.swift`

### Step 4.1: Write the failing test

- [ ] **Step 4.1.1: Create the test file**

Create `Tests/UnitTests/EventWriterFileLockTests.swift`:

```swift
// Tests/UnitTests/EventWriterFileLockTests.swift
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import PulsarTraceEngine

@Suite("EventWriter cross-process file lock")
struct EventWriterFileLockTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-evtlock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Regression for the corrupted line observed in events/2026-05-20.jsonl
    /// where a recording_paused event from pulsartrace-capture was clobbered
    /// mid-write by an app_stopped event from pulsartrace-mac. EventWriter is
    /// an actor (serialises within a process) but doesn't lock across
    /// processes — flock(LOCK_EX) closes that gap.
    @Test("append blocks while a foreign fd holds LOCK_EX on the same file")
    func appendHonoursForeignFlock() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = EventWriter(directory: dir)
        await writer.bootstrap()

        let url = await writer.currentFileURL()
        // Foreign fd standing in for a second process. Must be a separate fd —
        // flock on the same fd from the same process is a no-op.
        let foreignFd = open(url.path, O_RDWR)
        #expect(foreignFd >= 0, "foreign open failed: errno \(errno)")
        defer { close(foreignFd) }
        #expect(flock(foreignFd, LOCK_EX) == 0, "foreign flock failed")

        let payload = AppStoppedEvent(version: "test", macosVersion: "test")
        let writeStarted = Date()
        let writeTask = Task { try await writer.append(payload) }

        // Give the actor a chance to enter append(); if it doesn't honour the
        // foreign lock the file will already have data.
        try await Task.sleep(for: .milliseconds(200))
        let mid = try Data(contentsOf: url)
        #expect(mid.isEmpty,
                "EventWriter wrote while a foreign LOCK_EX was held — cross-process lock missing")

        _ = flock(foreignFd, LOCK_UN)
        _ = try await writeTask.value
        let final = try Data(contentsOf: url)
        #expect(final.count > 0, "writer should have proceeded after the lock released")
        let elapsed = Date().timeIntervalSince(writeStarted)
        #expect(elapsed >= 0.2,
                "writer must have actually waited; only \(elapsed)s elapsed")
    }
}
```

If `AppStoppedEvent`'s init signature differs from the test, look at `Sources/PulsarTraceEngine/Events/Event.swift` for the real `AppStoppedEvent.init(...)` and adapt the call in the test before running. (One of the events used in the real log was `app_stopped` — pick whichever event type is simplest to construct in a test, the lock behaviour does not depend on payload shape.)

- [ ] **Step 4.1.2: Run — must fail**

```
swift test --filter EventWriterFileLock
```
Expected: `mid.isEmpty` expectation fails — EventWriter writes immediately, ignoring the foreign lock.

### Step 4.2: Implement the `flock` wrap

- [ ] **Step 4.2.1: Edit `EventWriter.swift`**

Edit `Sources/PulsarTraceEngine/Events/EventWriter.swift`.

Add the platform import at the top (after `import Foundation`):

```swift
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
```

Replace the body of `append<P:>(_:)` (currently lines 69-86). Find:

```swift
    @discardableResult
    public func append<P: EventPayload>(_ payload: P) throws -> String {
        rotateIfNeeded()
        let now = clock()
        let id = "evt_\(ulidFactory(now).value)"
        let envelope = Envelope(
            ts: Timestamps.event(now),
            type: P.eventType,
            id: id,
            version: P.schemaVersion
        )
        let line = try Self.encodeLine(envelope: envelope, payload: payload)
        guard let handle else { throw WriteError.noOpenFile }
        guard let data = (line + "\n").data(using: .utf8) else {
            throw WriteError.encodingFailed
        }
        try handle.write(contentsOf: data)
        return id
    }
```

Replace the last three lines (the `guard let handle` through `return id`) with the locked write:

```swift
        guard let handle else { throw WriteError.noOpenFile }
        guard let data = (line + "\n").data(using: .utf8) else {
            throw WriteError.encodingFailed
        }

        // Cross-process exclusion. Both `pulsartrace-mac` and
        // `pulsartrace-capture` append to the same daily file; the actor only
        // serialises within one process. Without flock, the two processes
        // can interleave bytes mid-line — observed in
        // events/2026-05-20.jsonl where a `recording_paused` was clobbered by
        // an `app_stopped`. `flock(LOCK_EX)` is advisory: it only guards
        // against other callers that also `flock` the file, which every
        // EventWriter does. Released in `defer` so a thrown `write` still
        // unlocks.
        let fd = handle.fileDescriptor
        guard flock(fd, LOCK_EX) == 0 else {
            throw WriteError.lockFailed(errno: errno)
        }
        defer { _ = flock(fd, LOCK_UN) }

        try handle.write(contentsOf: data)
        return id
    }
```

Add the new `WriteError` case (find the enum at lines 18-29):

```swift
    public enum WriteError: Error, CustomStringConvertible {
        /// No open file handle — the events file could not be opened.
        case noOpenFile
        /// The encoded line could not be converted to UTF-8 bytes.
        case encodingFailed
        /// `flock(2)` returned non-zero. `errno` is captured for diagnosability.
        case lockFailed(errno: Int32)

        public var description: String {
            switch self {
            case .noOpenFile: return "events file is not open; event not persisted"
            case .encodingFailed: return "event line could not be UTF-8 encoded"
            case .lockFailed(let e): return "events file flock failed: errno \(e)"
            }
        }
    }
```

- [ ] **Step 4.2.2: Run — must pass**

```
swift test --filter EventWriterFileLock
```
Expected: 1/1 pass.

- [ ] **Step 4.2.3: Run the broader events tests to confirm no regression**

```
swift test --filter EventWriter
```
Expected: every existing EventWriter test still passes alongside the new lock test.

- [ ] **Step 4.2.4: Commit**

```bash
git add Sources/PulsarTraceEngine/Events/EventWriter.swift \
        Tests/UnitTests/EventWriterFileLockTests.swift
git commit -m "$(cat <<'EOF'
fix(events): flock(LOCK_EX) on append so cross-process writers cannot interleave

EventWriter is an actor — it serialises within one process — but
pulsartrace-mac and pulsartrace-capture are separate processes both
appending to events/YYYY-MM-DD.jsonl. Without a cross-process lock,
their writes can interleave mid-line; events/2026-05-20.jsonl contains
a corrupted line where a recording_paused from the capture daemon was
clobbered by an app_stopped from the menubar app.

append() now acquires flock(LOCK_EX) on the file's fd before writing
and releases it via defer. Advisory lock — only mutually exclusive
against other flock callers — but every writer to this file is
EventWriter, so the contract holds. New WriteError.lockFailed surfaces
flock errno if it ever returns non-zero.
EOF
)"
```

---

## Task 5: Documentation sync

**Files:**
- Modify: `project-docs/DECISIONS.md` (rewrite D36, add D37)
- Modify: `project-docs/PLAN.md` (line 395 close-out note)
- Modify: `docs/events-schema.md` (note the advisory lock)

### Step 5.1: Rewrite D36 and add D37

- [ ] **Step 5.1.1: Rewrite `DECISIONS.md:801-805` (D36)**

Replace:
```markdown
## D36 — `WhisperTranscriber` is constructed per region inside the refiner

**Decision:** `ResumableRefiner` constructs a fresh `WhisperTranscriber` for each VAD region it transcribes (see the `transcribe:` closure built in `RefinementJobQueue.makeStandard`), rather than holding one instance across the job.

**Why:** `WhisperTranscriber` wraps `whisper_context`, which is non-Sendable and not thread-safe. Holding one across `await` suspensions inside the refiner's stage loop would require carrying non-Sendable state through Swift Concurrency, which is awkward and would force the refiner into the actor model purely to satisfy the type system. The model file is mmapped by whisper.cpp, so the OS page cache amortises the per-region construction cost — the actual overhead is whisper's per-context init (~tens of ms), which is negligible next to per-region transcribe time (seconds). This matches the pattern `OfflineRefiner` already uses for the CLI path, so both refine paths look the same from a reviewer's perspective.
```

With:
```markdown
## D36 (revised 2026-05-20) — `WhisperTranscriber` is reused across regions within a job

**Decision:** `RefinementJobQueue.makeStandard` builds one `WhisperTranscriber` per job via a `SharedTranscriberBox`, and the refiner's `transcribe:` closure pulls the same instance for every VAD region. `OfflineRefiner` / `RefinementPipeline.transcribe` already builds one transcriber per WAV (i.e. one per stream); the queue path now matches that locality.

**Why:** the original D36 decision held that per-region construction was negligible because the model file is mmapped, so the OS page cache amortised the cost. That reasoning was wrong on two fronts:

- The page cache covers the mmap'd weights only. `whisper_init_from_file_with_params` builds the **Metal pipeline state object**, allocates the KV cache, and initialises the GGML backend on every call — multi-second for `large-v3` on Apple Silicon, not "tens of ms".
- The claim that the per-region pattern "matches OfflineRefiner" was simply false — `RefinementPipeline.transcribe` already constructs the transcriber once per stream and reuses it across regions via `transcriber.transcribe(samples, regions:, options:)`.

Reopened after refining session `2026-05-20-100033` averaged ~78 s per VAD region of mostly short utterances — roughly two orders of magnitude slower than realistic decode time, dominated by repeated Metal pipeline initialisation. `SharedTranscriberBox` (a small `@unchecked Sendable` lazy single-instance wrapper) lets the existing `@Sendable` `transcribe:` closure capture the box and reuse one instance without changing `ResumableRefiner`'s public surface or breaking its unit tests. The queue is single-worker, so at most one box / one transcriber exists at any time, preserving D8's metalLock contract.

**Tradeoff:** holding the transcriber across a `pauseGate` close keeps ~3 GB resident for `large-v3` while the queue is paused for a recording. Accepted for v1 — the alternative (drop on pause, rebuild on resume) re-introduces the model-reload cost for the common short-pause case (stall recovery, hotkey toggle). If memory pressure surfaces in practice, a "drop after N seconds of idle pause" variant can be layered onto `SharedTranscriberBox` without changing call sites.

## D37 — `EventWriter.append` holds an advisory `flock(LOCK_EX)`

**Decision:** Every `EventWriter.append` call acquires `flock(LOCK_EX)` on the daily events file's fd before writing and releases it after. The events file is a shared resource between every process that links `PulsarTraceEngine` and writes — the capture daemon, the menubar app, and the CLI; the actor model only serialises within one process.

**Why:** an interleaved line was observed in `events/2026-05-20.jsonl` where a `recording_paused` from `pulsartrace-capture` was clobbered mid-write by an `app_stopped` from `pulsartrace-mac`. `flock` is cooperative — it only protects against other callers that also `flock` — but every writer of this file goes through `EventWriter`, so the contract is complete in-tree. Foundation's `FileHandle.write(contentsOf:)` resolves to a single `write(2)` system call, but `write(2)` is only atomic up to `PIPE_BUF` bytes; longer events would still split without the lock. The fix is the simplest thing that works and survives a hot rotation: the lock is per-fd and is released via `defer`.
```

- [ ] **Step 5.1.2: Update `PLAN.md:395`**

Replace the existing line 395 close-out bullet so it preserves what was finished and flags the corrections this plan addresses:

Current:
```markdown
- [x] Branch close-out: typed error classification (C3), settings closure removed (C5), pruneTerminal wired into queue start with 30-day retention, retain cycle in makeStandard broken via weak capture, PauseReason gains a displayName, placeholder queue uses a temp directory. The 250 ms polling cadence and per-region WhisperTranscriber construction are promoted to architectural decisions: DECISIONS D35 and D36.
```

New:
```markdown
- [x] Branch close-out: typed error classification (C3), settings closure removed (C5), pruneTerminal wired into queue start with 30-day retention, retain cycle in makeStandard broken via weak capture, PauseReason gains a displayName, placeholder queue uses a temp directory. The 250 ms polling cadence is promoted to D35.
- [x] **Follow-up landed in a separate change** (see `docs/specs/2026-05-20-refine-perf-and-capture-resilience-plan.md`): D36 reopened — `WhisperTranscriber` is reused across regions within a job via `SharedTranscriberBox`; `RefinementProgress` gains an optional `lastError` field that `ResumableRefiner.run` populates on failure; `DeviceCaptureSource.makeSystemEngine` now wires `onStreamError` into the stall-restart path (gap that surfaced on session 2026-05-20-113001); `EventWriter.append` acquires `flock(LOCK_EX)` (D37) so cross-process appends can no longer interleave.
```

- [ ] **Step 5.1.3: Append a note to `docs/events-schema.md`**

Open `docs/events-schema.md` and find a sensible spot near the existing "EventWriter" / "rotation" prose. Add a short paragraph:

```markdown
### Cross-process serialisation

Every `EventWriter.append` acquires an advisory `flock(LOCK_EX)` on the
daily file before writing. This protects against the otherwise-possible
case where `pulsartrace-mac` and `pulsartrace-capture` (each running
their own `EventWriter`) append concurrently and split a JSONL line
mid-byte. An external consumer that opens the file while appends are
in flight should expect to retry a partial tail read — `EventWriter`
itself never produces a partial line, but the on-disk state is only
*atomically complete* between flock-acquired writes.
```

- [ ] **Step 5.1.4: Commit**

```bash
git add project-docs/DECISIONS.md project-docs/PLAN.md docs/events-schema.md
git commit -m "$(cat <<'EOF'
docs: revise D36, add D37, note advisory flock in events-schema

D36 reopened — the original "matches OfflineRefiner" / "tens of ms"
reasoning was factually wrong on both counts. New text records the
SharedTranscriberBox approach and the memory-vs-perf tradeoff of
holding the transcriber across pauses.

D37 records EventWriter.append's flock(LOCK_EX) — the advisory lock
that closes the cross-process write race surfaced in
events/2026-05-20.jsonl.

PLAN.md's branch close-out bullet updated to point at this plan; the
events-schema.md gets a short paragraph for external readers.
EOF
)"
```

---

## Task 6: Tidy stale phase markers

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift:14-16`
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/Cancellable.swift:10`

### Step 6.1: Drop stale "B4 / B5 / B7" markers

- [ ] **Step 6.1.1: Edit `ResumableRefiner.swift:14-16`**

Find and delete these three lines from the doc comment of `public actor ResumableRefiner`:

```swift
/// B4 — happy-path stage iteration only. Pause/resume (gate-closing) is wired
/// in B5; `PauseGate` is already threaded through here so B5 can activate it
/// without changing the call sites.
```

(B5 is now wired — `pauseGate.waitOpen()` is called at every stage transition and between regions, so this comment is dead context.)

- [ ] **Step 6.1.2: Edit `Cancellable.swift:10`**

Find this line in the doc comment:

```swift
/// refiner's cancel-retry loop (B7) handles the eventual
```

Drop the parenthetical phase marker — keep the prose:

```swift
/// refiner's cancel-retry loop handles the eventual
```

- [ ] **Step 6.1.3: Verify tests still pass**

```
swift test --filter UnitTests
```
Expected: green — comment-only changes.

- [ ] **Step 6.1.4: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift \
        Sources/PulsarTraceEngine/Refinement/Jobs/Cancellable.swift
git commit -m "$(cat <<'EOF'
docs(refine): drop stale B4/B5/B7 phase markers from refiner doc comments

The B-series phase labels referred to in-flight plan tasks during the
refinement-queue branch; every one of them is wired and shipped, so the
markers are dead context. Removing them keeps the doc comments aligned
with what the code actually does.
EOF
)"
```

---

## Final verification

- [ ] **Step F.1: Run every relevant filter**

```
swift test --filter UnitTests
swift test --filter Refinement
swift test --filter StallRecovery
swift test --filter EventWriter
```

Each must return all-green. Do not run the broad `--filter PipelineTests` form — the project README documents that combination as known-flaky (`CLAUDE.md` "Known limitation"). The narrow filters above are deterministic.

- [ ] **Step F.2: Smoke-test the refinement perf win against session 100033**

Manual: in the menubar app, click "Refine" on `2026-05-20-100033` (or run the CLI `pulsartrace refine /Users/mateusz/Projects/meetings/pulsartrace/2026-05-20-100033/`). Watch `refine-progress.json` — `completed_system_region_indices` should grow at roughly the rate of one region per 3–7 seconds of wall time (typical decode time for a few seconds of audio on Apple Silicon), not the ~78 s/region observed in the un-fixed code path. If the rate is still above ~30 s/region, something other than per-region model load is dominating and the diagnosis needs revisiting before declaring the task done.

- [ ] **Step F.3: Confirm `lastError` lands on the next intentional failure**

Manual: set the model name on an enqueued job to a nonexistent name (or temporarily delete the model file before refine starts), enqueue a refine. After the failure, open the recording folder's `refine-progress.json` and verify `last_error` carries the underlying message (e.g. `modelLoadFailed: <folder>/…`).

- [ ] **Step F.4: Confirm the events log no longer interleaves**

Manual: start a recording, then within ~10s stop and start it again. Inspect `~/Library/Application Support/PulsarTrace/events/<today>.jsonl` — every line must parse as JSON. Run `jq -c . < <today>.jsonl > /dev/null` (or equivalent) and confirm zero parse errors. (A previous run produced a line where `recording_paused` and `app_stopped` were spliced together; that line is the witness that flock was missing.)

---

## Out of scope (deliberate, but worth recording)

- **Engine-side wedge that may also have contributed to the 17-min cutoff.** Even if every `SCStream` failure now triggers a restart, the engine's run loop in `LiveRunner` could still wedge if the live-md sink or speaker-library SQLite read blocked an `await sink.appendXyz` for long enough that frames stopped reaching the WAV writer at the same wall time as live.md stopped advancing — that's consistent with what was observed on session 113001. A targeted look at the speaker-library SQLite read path in the live loop is a separate piece of work, not blocked by anything here.
- **`RefinementJobError.classify` coverage of `RefinementPipeline.RefineError`.** The doc comment in `RefinementJobError.swift` claims that branch can show up, but the implementation does not match against `RefineError`. In practice `ResumableRefiner` rethrows raw errors and does not wrap them, so the doc is wrong rather than the code. Easier to update the doc when next touching that file — not worth a churn-only commit now.
- **Updating `RefinementPipeline.transcribe` to use `SharedTranscriberBox` too.** That path already builds one transcriber per stream (good enough — single-digit number of loads per refine). The queue path was the pathological case; both paths now sit within an order of magnitude of each other.
