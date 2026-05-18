import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `StreamingWAVWriter` — the incremental, crash-safe variant
/// of the canonical Int16 WAV storage format (R54e). The key guarantee under
/// test: the file on disk is *always* a valid, correctly-sized WAV reflecting
/// what was appended, even if `finalize()` is never reached.
@Suite("StreamingWAVWriter (R54e, crash-safe)")
struct StreamingWAVWriterTests {

    /// A scratch WAV path that is removed when `body` returns.
    private func withTempWAV(_ body: (URL) throws -> Void) rethrows {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-swav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try body(tmp)
    }

    @Test("Incremental write is byte-equivalent to a one-shot WAVWriter encode")
    func byteEquivalentToOneShot() throws {
        try withTempWAV { url in
            var samples: [Float] = []
            for i in 0..<5000 {
                samples.append(Float(sin(Double(i) * 0.03)) * 0.7)
            }

            // Stream the samples in a few irregularly-sized chunks.
            let writer = try StreamingWAVWriter(url: url)
            var i = 0
            for chunk in [120, 1600, 33, 2047, 1200] {
                try writer.append(Array(samples[i..<i + chunk]))
                i += chunk
            }
            try writer.append(Array(samples[i...]))
            try writer.finalize()

            let streamed = try Data(contentsOf: url)
            let oneShot = WAVWriter.encode(samples: samples)
            #expect(streamed == oneShot)

            // And it reads back to the same samples.
            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.sampleRate == 16_000)
            #expect(decoded.samples.count == samples.count)
            for (o, r) in zip(samples, decoded.samples) {
                #expect(abs(o - r) < 7e-5)
            }
        }
    }

    @Test("File is a valid, correctly-sized WAV even without finalize() (crash)")
    func validWithoutFinalize() throws {
        try withTempWAV { url in
            // 3 seconds of audio so several header re-patches happen.
            let samples = (0..<(16_000 * 3)).map {
                Float(sin(Double($0) * 0.02)) * 0.5
            }
            let writer = try StreamingWAVWriter(url: url)
            // Append in 0.5s frames, then *do not* finalize — simulate a kill.
            var i = 0
            while i < samples.count {
                let end = min(i + 8_000, samples.count)
                try writer.append(Array(samples[i..<end]))
                i = end
            }
            // No finalize(): read straight off disk.
            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.sampleRate == 16_000)
            // The header is patched ~once/second, so the on-disk WAV reflects
            // all-but at most the last <1s of appended audio.
            #expect(decoded.samples.count <= samples.count)
            #expect(decoded.samples.count >= samples.count - 16_000)
            // What it does contain must be an exact prefix of the input.
            for (o, r) in zip(samples, decoded.samples) {
                #expect(abs(o - r) < 7e-5)
            }
        }
    }

    @Test("File on disk is valid mid-stream, after the first header patch")
    func validMidStream() throws {
        try withTempWAV { url in
            let writer = try StreamingWAVWriter(url: url)
            // Append >1s of audio so at least one header patch has run.
            let chunk = (0..<20_000).map { _ in Float(0.3) }
            try writer.append(chunk)

            // Read while the writer is still "open" — no finalize yet.
            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.samples.count == chunk.count)
            #expect(decoded.samples.allSatisfy { abs($0 - 0.3) < 7e-5 })

            try writer.finalize()
        }
    }

    @Test("Empty writer + finalize() yields a valid 0-sample WAV")
    func emptyWriter() throws {
        try withTempWAV { url in
            let writer = try StreamingWAVWriter(url: url)
            try writer.finalize()

            let data = try Data(contentsOf: url)
            #expect(data.count == 44)
            #expect(data == WAVWriter.encode(samples: []))

            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.samples.isEmpty)
            #expect(decoded.sampleRate == 16_000)
        }
    }

    @Test("Empty writer is a valid 0-sample WAV even without finalize()")
    func emptyWriterNoFinalize() throws {
        try withTempWAV { url in
            _ = try StreamingWAVWriter(url: url)
            // The 44-byte header was written in init — already a valid WAV.
            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.samples.isEmpty)
        }
    }

    @Test("finalize() is idempotent")
    func finalizeIsIdempotent() throws {
        try withTempWAV { url in
            let writer = try StreamingWAVWriter(url: url)
            try writer.append([0.1, 0.2, -0.3])
            try writer.finalize()
            // Calling again must not throw and must not corrupt the file.
            try writer.finalize()
            try writer.finalize()

            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.samples.count == 3)
        }
    }

    @Test("append() after finalize() is a no-op (does not corrupt the WAV)")
    func appendAfterFinalizeIsNoOp() throws {
        try withTempWAV { url in
            let writer = try StreamingWAVWriter(url: url)
            try writer.append([0.1, 0.2, 0.3])
            try writer.finalize()
            // A stray append after finalize must not throw or alter the file.
            try writer.append([0.9, 0.9])

            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.samples.count == 3)
        }
    }

    @Test("Appending an empty sample buffer is a harmless no-op")
    func appendEmptyBuffer() throws {
        try withTempWAV { url in
            let writer = try StreamingWAVWriter(url: url)
            try writer.append([])
            try writer.append([0.5])
            try writer.append([])
            try writer.finalize()

            let decoded = try WAVReader(contentsOf: url)
            #expect(decoded.samples.count == 1)
        }
    }
}
