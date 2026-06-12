> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 09: FluidVADRegionDetector

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/FluidVADRegionDetector.swift`
- Test: `Tests/PipelineTests/FluidVADTests.swift`

- [ ] **Step 1: Write the failing integration test**

`Tests/PipelineTests/FluidVADTests.swift`:

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// Integration coverage for the FluidAudio (Silero-CoreML) VAD region
/// detector. Downloads the small VAD model on first run.
@Suite("FluidVAD region detection", .serialized)
struct FluidVADTests {

    @Test func findsSpeechRegionsInAFixture() async throws {
        let detector = FluidVADRegionDetector()
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio/two-speakers-alternating.wav")
        let samples = try WAVReader(contentsOf: fixture).samples
        let regions = try await detector.detectRegions(samples)
        #expect(!regions.isEmpty)
        let duration = Duration.milliseconds(samples.count * 1000 / AudioFormat.sampleRate)
        var previousEnd = Duration.zero - .milliseconds(1)
        for region in regions {
            #expect(region.start >= .zero)
            #expect(region.end <= duration + .seconds(1))
            #expect(region.end > region.start)
            #expect(region.start > previousEnd)   // sorted, non-overlapping
            previousEnd = region.end
        }
    }

    @Test func silenceYieldsNoRegions() async throws {
        let detector = FluidVADRegionDetector()
        let silence = [Float](repeating: 0, count: AudioFormat.sampleRate * 5)
        let regions = try await detector.detectRegions(silence)
        #expect(regions.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FluidVAD` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL — type not found.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/FluidVADRegionDetector.swift`:

```swift
import FluidAudio
import Foundation
import Logging

/// Speech-region detection for the ANE refine path: FluidAudio's Silero
/// VAD (CoreML, `.cpuAndNeuralEngine` by default) replaces whisper.cpp's
/// built-in Silero (the old `WhisperTranscriber.detectSpeechRegions`) so
/// the WhisperKit pipeline never has to construct a ggml context.
///
/// Regions are coalesced with the same 800 ms `minTurnGap` rule via
/// `SpeechRegion.coalesced` — the D26 turn-sizing contract (final.md breaks
/// at genuine conversational pauses) is backend-independent.
///
/// The VAD model (~small, `FluidInference/silero-vad-coreml`) is loaded
/// lazily on first use; FluidAudio caches it. A failure here is the
/// caller's fallback decision (whole-buffer decode / one whole-file region).
public actor FluidVADRegionDetector {

    private let minTurnGap: Duration
    private let logger: Logger
    private var manager: VadManager?

    public init(
        minTurnGap: Duration = .milliseconds(800),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.minTurnGap = minTurnGap
        self.logger = logger
    }

    public func detectRegions(_ samples: [Float]) async throws -> [SpeechRegion] {
        guard !samples.isEmpty else { return [] }
        let manager = try await ensureManager()
        let segments = try await manager.segmentSpeech(samples)
        let raw = segments.map { segment in
            SpeechRegion(
                start: .milliseconds(Int((segment.startTime * 1000).rounded())),
                end: .milliseconds(Int((segment.endTime * 1000).rounded())))
        }
        let coalesced = SpeechRegion.coalesced(raw, minGap: minTurnGap)
        logger.notice("fluid VAD: \(raw.count) region(s) → \(coalesced.count) turn(s)")
        return coalesced
    }

    private func ensureManager() async throws -> VadManager {
        if let manager { return manager }
        let created = try await VadManager()
        manager = created
        return created
    }
}
```

Note: `VadManager()` downloads to FluidAudio's own default directory. If `VadConfig`/`VadManager` (check the checkout's `Sources/FluidAudio/VAD/VadManager.swift`) exposes a model-directory parameter, point it at `ModelStore.defaultCacheDirectory().appendingPathComponent("silero-vad-coreml")` for cache-root consistency; if it only takes `VadConfig` without a directory, accept the SDK default and note it in the D39 entry (task 18) — do not fork the SDK over a cache path.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FluidVAD`
Expected: PASS (2 tests; first run downloads the VAD model).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/FluidVADRegionDetector.swift Tests/PipelineTests/FluidVADTests.swift
git commit -m "feat(refine): FluidVADRegionDetector — Silero-CoreML speech regions with 800ms coalescing"
```
