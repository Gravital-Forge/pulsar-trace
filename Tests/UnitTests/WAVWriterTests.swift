import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the canonical Int16 WAV storage format (PT-R54e) and the
/// `WAVWriter` ↔ `WAVReader` round-trip.
@Suite("WAVWriter (PT-R54e)")
struct WAVWriterTests {

    @Test("Encoded WAV has a valid 44-byte RIFF/WAVE header")
    func headerIsValid() {
        let data = WAVWriter.encode(samples: [0, 0.5, -0.5, 1.0])
        #expect(data.count == 44 + 4 * 2)  // header + 4 Int16 samples
        #expect(data.prefix(4).elementsEqual(Array("RIFF".utf8)))
        #expect(data.subdata(in: 8..<12).elementsEqual(Array("WAVE".utf8)))
        #expect(data.subdata(in: 12..<16).elementsEqual(Array("fmt ".utf8)))
        #expect(data.subdata(in: 36..<40).elementsEqual(Array("data".utf8)))
    }

    @Test("Encoded WAV declares 16kHz mono 16-bit PCM")
    func formatFieldsAreCanonical() throws {
        let data = WAVWriter.encode(samples: [0.1, 0.2, 0.3])
        let wav = try WAVReader(data: data)
        #expect(wav.sampleRate == 16_000)
        #expect(wav.samples.count == 3)
    }

    @Test("Float→Int16 conversion clamps out-of-range samples")
    func conversionClamps() {
        #expect(WAVWriter.int16(from: 2.0) == 32767)
        #expect(WAVWriter.int16(from: -2.0) == -32767)
        #expect(WAVWriter.int16(from: 0.0) == 0)
        #expect(WAVWriter.int16(from: 1.0) == 32767)
    }

    @Test("Writer→Reader round-trip preserves samples within Int16 quantization")
    func roundTrip() throws {
        // A ramp + a few peaks; every value is exactly representable enough
        // that Int16 quantization keeps it within one LSB (~3e-5).
        var samples: [Float] = []
        for i in 0..<2000 {
            samples.append(Float(sin(Double(i) * 0.05)) * 0.8)
        }
        let data = WAVWriter.encode(samples: samples)
        let decoded = try WAVReader(data: data)

        #expect(decoded.samples.count == samples.count)
        for (original, restored) in zip(samples, decoded.samples) {
            // Int16 quantization step is 1/32767 ≈ 3.05e-5; allow 2 steps.
            #expect(abs(original - restored) < 7e-5)
        }
    }

    @Test("Round-trip through a file on disk")
    func fileRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let samples: [Float] = [0, 0.25, -0.25, 0.5, -0.5, 0.75]
        try WAVWriter.write(samples: samples, to: tmp)

        let decoded = try WAVReader(contentsOf: tmp)
        #expect(decoded.sampleRate == 16_000)
        #expect(decoded.samples.count == samples.count)
        for (o, r) in zip(samples, decoded.samples) {
            #expect(abs(o - r) < 7e-5)
        }
    }

    @Test("Empty sample buffer yields a valid 44-byte header-only WAV")
    func emptyBuffer() throws {
        let data = WAVWriter.encode(samples: [])
        #expect(data.count == 44)
        let wav = try WAVReader(data: data)
        #expect(wav.samples.isEmpty)
    }
}
