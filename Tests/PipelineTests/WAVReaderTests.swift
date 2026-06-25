import Testing
import Foundation
@testable import PulsarTraceEngine

/// Pipeline coverage of `WAVReader` against the committed 16 kHz mono Int16
/// fixtures (canonical storage format, PT-R54e).
@Suite("WAVReader")
struct WAVReaderTests {

    @Test("Reads a 16kHz mono fixture at the declared sample rate")
    func readsSampleRate() throws {
        let wav = try WAVReader(contentsOf: FixtureLocator.audio("single-speaker-30s.wav"))
        #expect(wav.sampleRate == 16_000)
    }

    @Test("Sample count matches the fixture's duration")
    func sampleCountMatchesDuration() throws {
        let wav = try WAVReader(contentsOf: FixtureLocator.audio("sine-440hz-5s.wav"))
        // 5 s at 16 kHz = 80_000 samples.
        #expect(wav.samples.count == 80_000)
    }

    @Test("Decoded samples are within the normalized [-1, 1] range")
    func samplesNormalized() throws {
        let wav = try WAVReader(contentsOf: FixtureLocator.audio("sine-440hz-5s.wav"))
        #expect(wav.samples.allSatisfy { $0 >= -1.0 && $0 <= 1.0 })
    }

    @Test("A non-WAV input is rejected with a clear error")
    func rejectsNonWAV() {
        #expect(throws: WAVReader.WAVError.self) {
            _ = try WAVReader(data: Data("not a wav file".utf8))
        }
    }
}
