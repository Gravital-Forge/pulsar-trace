import Foundation
import Testing
@testable import PulsarTraceEngine

/// Tests for `WhisperTranscriber.transcribeRegion(_:region:options:)`.
///
/// The fixture-model test (`singleRegionMatchesMultiRegion`) requires a
/// committed ggml model at `Tests/Fixtures/whisper/ggml-base.bin`. That fixture
/// is not checked into the repo (models live in the shared cache accessed via
/// `ModelStore`); the test is therefore skipped in normal CI runs and must be
/// enabled manually by dropping the model file at the expected path. The
/// `WhisperFixtureLocator.hasModel` guard makes the skip explicit and
/// grep-friendly.
@Suite("WhisperTranscriber per-region API")
struct WhisperRegionTests {

    @Test("a single region decoded individually matches the multi-region call",
          .enabled(if: WhisperFixtureLocator.hasModel))
    func singleRegionMatchesMultiRegion() throws {
        let modelURL = try WhisperFixtureLocator.modelURL()
        let samples = try WhisperFixtureLocator.loadSamples("silence-then-speech")
        let transcriber = try WhisperTranscriber(modelURL: modelURL, useGPU: false)

        let regions: [SpeechRegion] = [
            SpeechRegion(start: .seconds(0), end: .seconds(1)),
            SpeechRegion(start: .seconds(1), end: .seconds(2)),
        ]
        let combined = try transcriber.transcribe(samples, regions: regions)

        let r0 = try transcriber.transcribeRegion(
            samples, region: regions[0], options: .init())
        let r1 = try transcriber.transcribeRegion(
            samples, region: regions[1], options: .init())

        #expect(r0.segments + r1.segments == combined.segments)
    }
}

// MARK: - Fixture helpers

/// Locates committed whisper model and audio fixtures for `WhisperRegionTests`.
///
/// Models are large and are therefore NOT committed to the repo — they live in
/// the shared `~/Library/Caches/PulsarTrace/models/` cache and are fetched via
/// `ModelStore`. To run the guarded tests locally, copy or symlink a
/// `ggml-base.bin` to `Tests/Fixtures/whisper/ggml-base.bin`.
enum WhisperFixtureLocator {

    /// `true` when a ggml model file is present at the fixture path.
    static var hasModel: Bool { (try? modelURL()) != nil }

    /// URL of the committed `ggml-base.bin` under `Tests/Fixtures/whisper/`.
    ///
    /// Throws if the file does not exist — the caller should guard with
    /// `hasModel` or use `.enabled(if: WhisperFixtureLocator.hasModel)`.
    static func modelURL() throws -> URL {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/UnitTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/whisper/ggml-base.bin")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw NSError(domain: "WhisperFixtureLocator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "No model at \(candidate.path). Drop ggml-base.bin there to run fixture tests."])
        }
        return candidate
    }

    /// Mono Float32 samples from a committed WAV at `Tests/Fixtures/audio/<name>.wav`.
    ///
    /// Uses `WAVReader` (the engine's own decoder) — no helper duplication.
    static func loadSamples(_ name: String) throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/UnitTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/audio/\(name).wav")
        return try WAVReader(contentsOf: url).samples
    }
}
