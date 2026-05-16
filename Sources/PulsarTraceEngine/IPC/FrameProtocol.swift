import Foundation

/// The `capture.sock` binary frame protocol (R76, §17).
///
/// `pulsartrace-capture` (Epic 7) writes PCM frames to a Unix domain socket;
/// `pulsartrace-engine` reads them via `SocketSource`. The same framing is used
/// when piping raw PCM into the engine over stdin. In Epic 1 there is no real
/// producer — only the codec and the consuming sources exist.
///
/// Wire format, per frame:
///
///     ┌──────────────┬─────────────────────────────┐
///     │ length: u32  │ payload: <length> bytes      │
///     │ little-endian│ little-endian Float32 samples │
///     └──────────────┴─────────────────────────────┘
///
/// `length` is the payload byte count (`samples * 4`). A length of `0` is the
/// explicit end-of-stream sentinel (R75): the producer writes one zero-length
/// frame, then closes. Consumers also treat a clean EOF (no more bytes) as
/// end-of-stream so an abruptly-closed producer still terminates cleanly.
public enum FrameProtocol {

    /// The end-of-stream sentinel: a frame whose declared length is zero.
    public static let endOfStreamLength: UInt32 = 0

    /// Maximum payload size accepted from a peer, as a sanity guard against a
    /// corrupt length prefix. A 20 ms frame is 1280 bytes; 1 MiB is generous.
    public static let maxPayloadBytes: Int = 1 << 20

    public enum FrameError: Error, CustomStringConvertible, Equatable {
        case payloadTooLarge(Int)
        case payloadNotFloatAligned(Int)

        public var description: String {
            switch self {
            case .payloadTooLarge(let n): return "frame payload \(n) bytes exceeds maximum"
            case .payloadNotFloatAligned(let n): return "frame payload \(n) bytes is not Float32-aligned"
            }
        }
    }

    /// Encode a single frame to wire bytes (length prefix + Float32 payload).
    public static func encode(_ frame: AudioFrame) -> Data {
        var out = Data()
        let payloadBytes = frame.samples.count * MemoryLayout<Float>.size
        out.append(littleEndianU32(UInt32(payloadBytes)))
        out.append(littleEndianFloats(frame.samples))
        return out
    }

    /// Encode the end-of-stream sentinel frame.
    public static func encodeEndOfStream() -> Data {
        littleEndianU32(endOfStreamLength)
    }

    /// Decode a payload of little-endian Float32 bytes into samples.
    public static func decodePayload(_ payload: Data) throws -> [Float] {
        guard payload.count <= maxPayloadBytes else {
            throw FrameError.payloadTooLarge(payload.count)
        }
        guard payload.count % MemoryLayout<Float>.size == 0 else {
            throw FrameError.payloadNotFloatAligned(payload.count)
        }
        let count = payload.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        if count > 0 {
            samples.withUnsafeMutableBytes { dst in
                payload.copyBytes(to: dst.bindMemory(to: UInt8.self))
            }
            // Bytes are little-endian; on a little-endian host (arm64) this is
            // a no-op, but normalize explicitly for correctness.
            samples = samples.map { sample -> Float in
                Float(bitPattern: UInt32(littleEndian: sample.bitPattern))
            }
        }
        return samples
    }

    // MARK: - Little-endian helpers

    static func littleEndianU32(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    static func littleEndianFloats(_ samples: [Float]) -> Data {
        var out = Data(capacity: samples.count * 4)
        for sample in samples {
            var le = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }
}
