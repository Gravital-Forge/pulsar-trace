> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 07: ParakeetWindowTranscriber — the WindowTranscribing conformer

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetWindowTranscriber.swift`
- Test: append to `Tests/PipelineTests/ParakeetTranscriberTests.swift` (created in task 06)

- [ ] **Step 1: Write the failing tests (append inside the `ParakeetTranscriberTests` suite from task 06)**

```swift
    @Test func conformsToWindowTranscribingWithAbsoluteTimestamps() async throws {
        let engine = try await Self.engineTask.value
        let transcriber: any WindowTranscribing = ParakeetWindowTranscriber(engine: engine)
        let window = try Self.fixtureSamples(seconds: 10)
        let result = try transcriber.transcribeWindow(
            window, windowStart: .seconds(60), options: WhisperOptions(), abort: nil)
        #expect(!result.segments.isEmpty)
        for seg in result.segments {
            // Shifted onto the recording timeline: window starts at 60 s.
            #expect(seg.start >= .seconds(60))
            #expect(seg.end <= .seconds(71))
            #expect(!seg.text.isEmpty)
        }
    }

    @Test func subMinimumWindowReturnsEmptyInsteadOfThrowing() async throws {
        // Parakeet rejects audio under 300 ms; the end-of-stream flush can
        // produce such a tail. Contract: empty result, not an error.
        let engine = try await Self.engineTask.value
        let transcriber = ParakeetWindowTranscriber(engine: engine)
        let result = try transcriber.transcribeWindow(
            [Float](repeating: 0.1, count: 1600),   // 100 ms
            windowStart: .zero, options: WhisperOptions(), abort: nil)
        #expect(result.segments.isEmpty)
    }

    @Test func allowedLanguagesSingletonFlowsAsScriptHint() async throws {
        // options.allowedLanguages == ["en"] → languageHint "en" → still a
        // non-empty English decode (the hint steers token scripts, it does
        // not gate output).
        let engine = try await Self.engineTask.value
        let transcriber = ParakeetWindowTranscriber(engine: engine)
        var options = WhisperOptions()
        options.allowedLanguages = ["en"]
        let window = try Self.fixtureSamples(seconds: 8)
        let result = try transcriber.transcribeWindow(
            window, windowStart: .zero, options: options, abort: nil)
        #expect(!result.segments.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter Parakeet` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL — `cannot find 'ParakeetWindowTranscriber' in scope`.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetWindowTranscriber.swift`:

```swift
import Foundation
import Logging

/// `WindowTranscribing` over the resident `ParakeetEngine` (live pass).
///
/// `transcribeWindow` is a synchronous protocol requirement invoked from
/// `LiveRunner`'s GCD offload queue (blocking there is by design — the old
/// whisper path blocked in `whisper_full` the same way). The engine is an
/// actor with an async API, so this bridges with a semaphore: spawn the
/// decode as a `Task`, block the GCD thread until it signals. No deadlock
/// risk — the cooperative pool is never the waiting thread.
///
/// `abort` is ignored, like the old `RemoteWindowTranscriber`: a CoreML
/// predict can't be interrupted mid-graph. Instead a 30 s semaphore deadline
/// bounds a wedged decode — the window is skipped (`StreamingTranscriber`
/// logs and carries on; the post-pass recovers the audio) and the orphaned
/// Task's eventual result is discarded. A 10 s window decodes in well under
/// 1 s on an M2 ANE, so the deadline only fires on genuine wedges.
///
/// Language: when the "Restrict to languages" selector holds exactly one
/// code (`options.allowedLanguages`), it flows to FluidAudio as the
/// script-aware hint; otherwise the decode is auto (scope decision 3).
///
/// Construct one per stream; both share one `ParakeetEngine` (the actor
/// serializes decodes). Not Sendable, same as every `WindowTranscribing`
/// conformer — owned by the live worker task.
public final class ParakeetWindowTranscriber: WindowTranscribing {

    /// Parakeet's hard input floor (`ASRConstants.minimumAudioDurationSeconds`
    /// = 0.3 s). Shorter windows return an empty result instead of tripping
    /// `ASRError.invalidAudioData` on every end-of-stream tail flush.
    static let minimumSamples = AudioFormat.sampleRate * 3 / 10

    /// Wall-clock bound on one window decode before it is abandoned.
    static let decodeDeadline: DispatchTimeInterval = .seconds(30)

    /// NSLock-guarded result slot — the decode Task writes, the blocked
    /// caller reads after the semaphore fires. `@unchecked Sendable`: all
    /// access is lock-protected.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<ParakeetEngine.WindowDecode, Error>?
        func set(_ v: Result<ParakeetEngine.WindowDecode, Error>) {
            lock.lock(); defer { lock.unlock() }
            value = v
        }
        func take() -> Result<ParakeetEngine.WindowDecode, Error>? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private let engine: ParakeetEngine
    private let logger: Logger

    public init(
        engine: ParakeetEngine,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.engine = engine
        self.logger = logger
    }

    public func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperOptions,
        abort: AbortToken?
    ) throws -> TranscriptionResult {
        guard samples.count >= Self.minimumSamples else {
            return TranscriptionResult(segments: [], language: "unknown")
        }

        let hint = ParakeetEngine.languageHint(from: options.allowedLanguages)
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let engine = self.engine
        Task {
            do {
                box.set(.success(try await engine.transcribeWindow(
                    samples, languageHint: hint)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.decodeDeadline) == .success,
              let outcome = box.take() else {
            logger.error("parakeet window decode exceeded deadline — skipping window")
            throw WhisperTranscribeError.transcriptionFailed(-2)
        }

        let decode = try outcome.get()
        let windowDuration = Duration.milliseconds(
            samples.count * 1000 / AudioFormat.sampleRate)
        return ParakeetTokenMapper.transcriptionResult(
            tokens: decode.tokens,
            fallbackText: decode.text,
            windowStart: windowStart,
            windowDuration: windowDuration)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter Parakeet`
Expected: PASS (all suite tests, including task 06's).

- [ ] **Step 5: Run the untouched live suites to prove no regression**

Run: `swift test --filter Streaming`
Run: `swift test --filter LiveRunner`
Expected: PASS — nothing in the existing live path changed yet.

- [ ] **Step 6: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetWindowTranscriber.swift Tests/PipelineTests/ParakeetTranscriberTests.swift
git commit -m "feat(live): ParakeetWindowTranscriber — WindowTranscribing on the ANE"
```
