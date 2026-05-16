import Foundation

/// Minimal RIFF/WAVE PCM reader.
///
/// PulsarTrace's canonical on-disk storage format is 16 kHz mono Int16 PCM
/// (R54e); fixture WAVs are produced that way by ffmpeg. This reader decodes
/// such files to the engine's canonical in-memory format (Float32 [-1, 1]).
/// It deliberately supports only what fixtures need: uncompressed PCM, Int16
/// or Float32, mono or stereo (downmixed), at any sample rate (caller must
/// ensure 16 kHz — fixtures are committed at 16 kHz).
public struct WAVReader {

    public enum WAVError: Error, CustomStringConvertible, Equatable {
        case notRIFF
        case notWAVE
        case missingFormatChunk
        case missingDataChunk
        case unsupportedFormat(tag: Int)
        case unsupportedBitDepth(Int)
        case truncated

        public var description: String {
            switch self {
            case .notRIFF: return "not a RIFF container"
            case .notWAVE: return "not a WAVE file"
            case .missingFormatChunk: return "missing 'fmt ' chunk"
            case .missingDataChunk: return "missing 'data' chunk"
            case .unsupportedFormat(let tag): return "unsupported WAV format tag \(tag)"
            case .unsupportedBitDepth(let bits): return "unsupported bit depth \(bits)"
            case .truncated: return "file truncated before declared data length"
            }
        }
    }

    /// Decoded sample rate (Hz) from the file header.
    public let sampleRate: Int
    /// Mono Float32 samples in [-1, 1]. Stereo input is downmixed by averaging.
    public let samples: [Float]

    /// Decode a WAV file at `url`.
    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    /// Decode WAV bytes already in memory.
    public init(data: Data) throws {
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset + 4 <= data.count else { throw WAVError.truncated }
            return data.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                return UInt32(b[offset]) | (UInt32(b[offset + 1]) << 8)
                    | (UInt32(b[offset + 2]) << 16) | (UInt32(b[offset + 3]) << 24)
            }
        }
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset + 2 <= data.count else { throw WAVError.truncated }
            return data.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                return UInt16(b[offset]) | (UInt16(b[offset + 1]) << 8)
            }
        }
        func tag(_ offset: Int) throws -> String {
            guard offset + 4 <= data.count else { throw WAVError.truncated }
            return String(decoding: data[offset..<offset + 4], as: UTF8.self)
        }

        guard data.count >= 12 else { throw WAVError.truncated }
        guard try tag(0) == "RIFF" else { throw WAVError.notRIFF }
        guard try tag(8) == "WAVE" else { throw WAVError.notWAVE }

        var formatTag = 0
        var channels = 0
        var rate = 0
        var bitsPerSample = 0
        var dataRange: Range<Int>?

        // Walk the chunk list starting just after "WAVE".
        var cursor = 12
        while cursor + 8 <= data.count {
            let chunkID = try tag(cursor)
            let chunkSize = Int(try u32(cursor + 4))
            let body = cursor + 8
            switch chunkID {
            case "fmt ":
                formatTag = Int(try u16(body))
                channels = Int(try u16(body + 2))
                rate = Int(try u32(body + 4))
                bitsPerSample = Int(try u16(body + 14))
            case "data":
                let end = min(body + chunkSize, data.count)
                guard body <= end else { throw WAVError.truncated }
                dataRange = body..<end
            default:
                break
            }
            // Chunks are word-aligned: skip an odd-length pad byte.
            cursor = body + chunkSize + (chunkSize % 2)
        }

        guard channels > 0, rate > 0, bitsPerSample > 0 else {
            throw WAVError.missingFormatChunk
        }
        guard let range = dataRange else { throw WAVError.missingDataChunk }

        // formatTag 1 = PCM integer, 3 = IEEE float, 0xFFFE = WAVE_FORMAT_EXTENSIBLE.
        let pcmData = data.subdata(in: range)
        var mono: [Float] = []

        switch (formatTag, bitsPerSample) {
        case (1, 16), (0xFFFE, 16):
            let frameCount = pcmData.count / (2 * channels)
            mono.reserveCapacity(frameCount)
            pcmData.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for f in 0..<frameCount {
                    var acc: Float = 0
                    for c in 0..<channels {
                        acc += Float(Int16(littleEndian: s[f * channels + c])) / 32768.0
                    }
                    mono.append(acc / Float(channels))
                }
            }
        case (3, 32), (0xFFFE, 32):
            let frameCount = pcmData.count / (4 * channels)
            mono.reserveCapacity(frameCount)
            pcmData.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: UInt32.self)
                for f in 0..<frameCount {
                    var acc: Float = 0
                    for c in 0..<channels {
                        acc += Float(bitPattern: UInt32(littleEndian: s[f * channels + c]))
                    }
                    mono.append(acc / Float(channels))
                }
            }
        case (1, let bits), (3, let bits), (0xFFFE, let bits):
            throw WAVError.unsupportedBitDepth(bits)
        default:
            throw WAVError.unsupportedFormat(tag: formatTag)
        }

        self.sampleRate = rate
        self.samples = mono
    }
}
