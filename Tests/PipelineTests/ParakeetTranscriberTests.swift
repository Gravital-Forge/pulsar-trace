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

    /// Run the blocking sync transcribe call on a GCD thread — the
    /// production calling context (`LiveRunner.offload`) — never on the
    /// cooperative pool, which the transcriber's semaphore bridge forbids.
    private static func onGCDThread<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private static func fixtureSamples(seconds: Int) throws -> [Float] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/PipelineTests
            .deletingLastPathComponent()    // Tests
            .appendingPathComponent("Fixtures/audio/single-speaker-30s.wav")
        let samples = try WAVReader(contentsOf: fixture).samples
        precondition(
            samples.count >= AudioFormat.sampleRate * seconds,
            "fixture shorter than requested window")
        return Array(samples.prefix(AudioFormat.sampleRate * seconds))
    }

    @Test func loadsAndDecodesAFixtureWindow() async throws {
        let engine = try await ParakeetTestEngine.shared()
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
        let engine = try await ParakeetTestEngine.shared()
        let window = try Self.fixtureSamples(seconds: 8)
        let first = try await engine.transcribeWindow(window, languageHint: nil)
        let second = try await engine.transcribeWindow(window, languageHint: nil)
        #expect(first.text == second.text)
    }

    @Test func hintedDecodeStillTranscribes() async throws {
        // The script hint must steer, not break: an English hint on the
        // English fixture decodes non-empty text. (An unknown code would
        // map to nil internally — auto — and also decode fine.)
        let engine = try await ParakeetTestEngine.shared()
        let window = try Self.fixtureSamples(seconds: 8)
        let decoded = try await engine.transcribeWindow(window, languageHint: "en")
        #expect(!decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func conformsToWindowTranscribingWithAbsoluteTimestamps() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let window = try Self.fixtureSamples(seconds: 10)
        let result = try await Self.onGCDThread {
            let transcriber: any WindowTranscribing = ParakeetWindowTranscriber(engine: engine)
            return try transcriber.transcribeWindow(
                window, windowStart: .seconds(60), options: TranscriptionOptions())
        }
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
        let engine = try await ParakeetTestEngine.shared()
        let result = try await Self.onGCDThread {
            let transcriber = ParakeetWindowTranscriber(engine: engine)
            return try transcriber.transcribeWindow(
                [Float](repeating: 0.1, count: 1600),   // 100 ms
                windowStart: .zero, options: TranscriptionOptions())
        }
        #expect(result.segments.isEmpty)
    }

    @Test func allowedLanguagesSingletonFlowsAsScriptHint() async throws {
        // options.allowedLanguages == ["en"] → languageHint "en" → still a
        // non-empty English decode (the hint steers token scripts, it does
        // not gate output).
        let engine = try await ParakeetTestEngine.shared()
        let window = try Self.fixtureSamples(seconds: 8)
        let result = try await Self.onGCDThread {
            let transcriber = ParakeetWindowTranscriber(engine: engine)
            var options = TranscriptionOptions()
            options.allowedLanguages = ["en"]
            return try transcriber.transcribeWindow(
                window, windowStart: .zero, options: options)
        }
        #expect(!result.segments.isEmpty)
    }
}
