import Foundation
import Logging
import Testing
@testable import PulsarTraceEngine

/// Integration coverage for the Parakeet live backend. Downloads the
/// ~0.5 GB CoreML bundle into the standard PulsarTrace model cache on first
/// run (network: huggingface.co — the permitted model-download call), then
/// reuses it. Serialized: one ANE model load at a time keeps memory sane.
@Suite("Parakeet live backend", .serialized)
struct ParakeetTranscriberTests {

    /// One engine per process — memoized Task, same race-free pattern as
    /// WhisperTestGate.model (a second caller awaits the in-flight load
    /// instead of starting a second download).
    private static let engineTask = Task<ParakeetEngine, Error> {
        try await ParakeetEngine.load(
            cacheRoot: ModelStore.defaultCacheDirectory(),
            events: nil,
            logger: Logger(label: "test.parakeet"))
    }

    private static func fixtureSamples(seconds: Int) throws -> [Float] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/PipelineTests
            .deletingLastPathComponent()    // Tests
            .appendingPathComponent("Fixtures/audio/single-speaker-30s.wav")
        let samples = try WAVReader(contentsOf: fixture).samples
        return Array(samples.prefix(AudioFormat.sampleRate * seconds))
    }

    @Test func loadsAndDecodesAFixtureWindow() async throws {
        let engine = try await Self.engineTask.value
        // 10 s window from the committed single-speaker fixture.
        let window = try Self.fixtureSamples(seconds: 10)
        let decoded = try await engine.transcribeWindow(window, languageHint: nil)
        #expect(!decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!decoded.tokens.isEmpty)
        // Timings are window-relative and inside the window.
        for token in decoded.tokens {
            #expect(token.start >= 0)
            #expect(token.end <= 10.5)
            #expect(token.end >= token.start)
        }
    }

    @Test func decodeIsDeterministicAcrossCalls() async throws {
        // LocalAgreement-2 requires two decodes of the same audio to agree.
        let engine = try await Self.engineTask.value
        let window = try Self.fixtureSamples(seconds: 8)
        let first = try await engine.transcribeWindow(window, languageHint: nil)
        let second = try await engine.transcribeWindow(window, languageHint: nil)
        #expect(first.text == second.text)
    }

    @Test func hintedDecodeStillTranscribes() async throws {
        // The script hint must steer, not break: an English hint on the
        // English fixture decodes non-empty text. (An unknown code would
        // map to nil internally — auto — and also decode fine.)
        let engine = try await Self.engineTask.value
        let window = try Self.fixtureSamples(seconds: 8)
        let decoded = try await engine.transcribeWindow(window, languageHint: "en")
        #expect(!decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
