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
///
/// ## Control frames (Epic 7)
///
/// A PCM frame's payload is always a positive multiple of 4 (Float32 samples).
/// `pulsartrace-capture` also needs to signal pause/resume (system sleep, R7;
/// device change, R8) in-band. Those use **control frames**: a length that is
/// neither `0` nor a multiple of 4 — a value a PCM frame can never have — whose
/// payload is a 1-byte opcode followed by opcode-specific data. The
/// read-exactly-`length`-bytes invariant is preserved, and the encoding is
/// purely additive: `FixtureSocketServer`, `PipeSource`, and every Epic 1–6
/// test write only frames + the zero-length EOS, so they are unaffected. See
/// `project-docs/DECISIONS.md` (D21).
public enum FrameProtocol {

    /// The end-of-stream sentinel: a frame whose declared length is zero.
    public static let endOfStreamLength: UInt32 = 0

    /// Maximum payload size accepted from a peer, as a sanity guard against a
    /// corrupt length prefix. A 20 ms frame is 1280 bytes; 1 MiB is generous.
    public static let maxPayloadBytes: Int = 1 << 20

    /// A decoded wire item. End-of-stream is *not* a case here — the reader
    /// signals it by finishing the stream (returning `nil`), exactly as a
    /// clean EOF does.
    public enum DecodedItem: Sendable, Equatable {
        /// A PCM frame's Float32 samples.
        case frame([Float])
        /// The producer's stream paused (system sleep / device change).
        case paused
        /// The producer's stream resumed; carries the paused gap in nanoseconds.
        case resumed(gapNanoseconds: UInt64)
    }

    /// The opcode byte that leads a control frame's payload.
    enum ControlOpcode: UInt8 {
        case paused = 1
        case resumed = 2
    }

    public enum FrameError: Error, CustomStringConvertible, Equatable {
        case payloadTooLarge(Int)
        case payloadNotFloatAligned(Int)
        case unknownControlFrame(Int)

        public var description: String {
            switch self {
            case .payloadTooLarge(let n): return "frame payload \(n) bytes exceeds maximum"
            case .payloadNotFloatAligned(let n): return "frame payload \(n) bytes is not Float32-aligned"
            case .unknownControlFrame(let n): return "unrecognized control frame, payload \(n) bytes"
            }
        }
    }

    /// `true` if `length` denotes a control frame — neither end-of-stream nor a
    /// Float32-aligned PCM frame. The reader decodes these via `decodeControl`.
    public static func isControlLength(_ length: UInt32) -> Bool {
        length != endOfStreamLength
            && length % UInt32(MemoryLayout<Float>.size) != 0
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

    /// Encode a "stream paused" control frame (length 1, opcode only).
    public static func encodeStreamPaused() -> Data {
        var out = littleEndianU32(1)
        out.append(ControlOpcode.paused.rawValue)
        return out
    }

    /// Encode a "stream resumed" control frame (length 9: opcode + an 8-byte
    /// little-endian `UInt64` paused-gap in nanoseconds).
    public static func encodeStreamResumed(gapNanoseconds: UInt64) -> Data {
        var out = littleEndianU32(9)
        out.append(ControlOpcode.resumed.rawValue)
        var le = gapNanoseconds.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        return out
    }

    /// Decode a control-frame payload (a leading opcode byte + opcode data).
    /// Throws `unknownControlFrame` for an unrecognized opcode or a truncated
    /// payload — a corrupt producer ends the consumer's stream with an error.
    public static func decodeControl(_ payload: Data) throws -> DecodedItem {
        guard let first = payload.first,
              let opcode = ControlOpcode(rawValue: first) else {
            throw FrameError.unknownControlFrame(payload.count)
        }
        switch opcode {
        case .paused:
            return .paused
        case .resumed:
            guard payload.count >= 9 else {
                throw FrameError.unknownControlFrame(payload.count)
            }
            let gapBytes = Array(payload.dropFirst().prefix(8))
            var gap: UInt64 = 0
            for i in 0..<8 { gap |= UInt64(gapBytes[i]) << (8 * i) }
            return .resumed(gapNanoseconds: gap)
        }
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
