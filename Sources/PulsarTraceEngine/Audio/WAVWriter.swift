import Foundation

/// Writes the canonical PulsarTrace storage format: 16 kHz mono **Int16** PCM
/// WAV (R54e).
///
/// R54e fixes one storage format end-to-end (~60 MB/hour). Resampling and
/// downmixing happen at the `AudioFrameSource` boundary, so by the time audio
/// reaches storage it is already 16 kHz mono — this writer only converts the
/// engine's in-memory Float32 to Int16 and frames a RIFF/WAVE container.
/// `WAVReader` decodes exactly what this produces (round-trip).
public struct WAVWriter {

    /// Float32 [-1, 1] → Int16, with clamping so an out-of-range sample can't
    /// wrap. Symmetric scaling by 32767 keeps +1.0 and -1.0 in range.
    static func int16(from sample: Float) -> Int16 {
        let clamped = Swift.min(1.0, Swift.max(-1.0, sample))
        return Int16((clamped * 32767.0).rounded())
    }

    /// Encode mono Float32 samples to a 16 kHz mono Int16 PCM WAV byte buffer.
    ///
    /// - Parameters:
    ///   - samples: mono PCM in [-1, 1].
    ///   - sampleRate: defaults to the canonical 16 kHz; callers should not
    ///     deviate (storage format is fixed by R54e).
    public static func encode(
        samples: [Float],
        sampleRate: Int = AudioFormat.sampleRate
    ) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample
        let dataSize = samples.count * bytesPerSample
        let riffSize = 36 + dataSize

        var data = Data(capacity: 44 + dataSize)

        func append32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func append16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        // RIFF header.
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(riffSize))
        data.append(contentsOf: Array("WAVE".utf8))

        // fmt chunk (PCM, format tag 1).
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                       // PCM fmt chunk size
        append16(1)                        // format tag: PCM integer
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))

        // data chunk.
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        data.reserveCapacity(data.count + dataSize)
        for sample in samples {
            append16(UInt16(bitPattern: int16(from: sample)))
        }
        return data
    }

    /// Encode and atomically write a WAV to `url`.
    public static func write(
        samples: [Float],
        to url: URL,
        sampleRate: Int = AudioFormat.sampleRate
    ) throws {
        let data = encode(samples: samples, sampleRate: sampleRate)
        try data.write(to: url, options: .atomic)
    }
}
