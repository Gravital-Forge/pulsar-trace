import Foundation
import Logging
import Testing
@testable import PulsarTraceEngine

/// Integration coverage for the WhisperKit ANE refine backend. First run
/// downloads the ~626 MB large-v3-turbo bundle + tokenizer and pays CoreML
/// ANE specialization (can take minutes once per OS install) — later runs
/// are warm.
@Suite("WhisperKit refine backend", .serialized)
struct WhisperKitRefineTests {

    /// One lazily-loading transcriber per process: construction is cheap,
    /// the actor loads the model on first decode and serializes use.
    private static let transcriber = WhisperKitRegionTranscriber(
        configuration: .init(
            model: WhisperKitModelCatalog.largeV3Turbo,
            downloadBase: ModelStore.defaultCacheDirectory()
                .appendingPathComponent("whisperkit", isDirectory: true)),
        events: nil)

    private static func fixtureSamples(_ name: String) throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio/\(name)")
        return try WAVReader(contentsOf: url).samples
    }

    @Test func decodesARegionWithAbsoluteTimestamps() async throws {
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let region = SpeechRegion(start: .seconds(2), end: .seconds(12))
        let result = try await Self.transcriber.transcribe(
            samples, regions: [region], options: WhisperOptions())
        #expect(!result.segments.isEmpty)
        for seg in result.segments {
            #expect(seg.start >= .seconds(1))    // slack: whisper pads edges
            #expect(seg.end <= .seconds(13))
            #expect(!seg.text.isEmpty)
        }
    }

    @Test func languagePinningIsHonored() async throws {
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let region = SpeechRegion(start: .zero, end: .seconds(10))
        var options = WhisperOptions()
        options.language = "en"
        let result = try await Self.transcriber.transcribe(
            samples, regions: [region], options: options)
        #expect(result.language == "en")
        #expect(!result.segments.isEmpty)
    }

    @Test func detectAmongPinsTheBestAllowedLanguage() async throws {
        // Delta B rule 3: several allowed codes → detect on the region
        // slice, pin the argmax within the allowed set. English fixture +
        // ["en", "pl"] must resolve to "en" and decode non-empty.
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let region = SpeechRegion(start: .zero, end: .seconds(10))
        var options = WhisperOptions()
        options.allowedLanguages = ["en", "pl"]
        let result = try await Self.transcriber.transcribe(
            samples, regions: [region], options: options)
        #expect(result.language == "en")
        #expect(!result.segments.isEmpty)
    }

    @Test func emptyRegionListDecodesWholeBuffer() async throws {
        // The `regions: []` contract = whole-buffer fallback, mirroring
        // the old `WhisperTranscriber.transcribe(_:regions:options:)`.
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let result = try await Self.transcriber.transcribe(
            samples, regions: [], options: WhisperOptions())
        #expect(!result.segments.isEmpty)
    }

    @Test func silentRegionProducesNoStockPhraseLines() async throws {
        // The D31 regression shape: digital silence must not yield
        // "Thank you."-style hallucinations on the new backend.
        let silence = [Float](repeating: 0, count: AudioFormat.sampleRate * 8)
        let result = try await Self.transcriber.transcribe(
            silence, regions: [SpeechRegion(start: .zero, end: .seconds(8))],
            options: WhisperOptions())
        // The digital-silence guard skips the decode entirely, so the region
        // yields no segments at all — the strongest statement of the fix.
        #expect(result.segments.isEmpty)
        // Kept: documents the D31 regression shape (a stock-phrase
        // hallucination on silence) the guard exists to prevent.
        for seg in result.segments {
            #expect(!HallucinationFilter.stockPhrases.contains(
                HallucinationFilter.normalize(seg.text)))
        }
    }
}
