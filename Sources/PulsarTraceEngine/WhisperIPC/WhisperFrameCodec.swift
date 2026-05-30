import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Length-prefixed JSON framing for the `pulsartrace-whisper` IPC channel
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md` §5).
///
/// Wire format, per frame:
///
///     ┌──────────────────────────┬──────────────────────────────┐
///     │ length: u32 big-endian   │ JSON payload, exactly N bytes │
///     └──────────────────────────┴──────────────────────────────┘
///
/// Why big-endian here, when `FrameProtocol` (the capture channel) uses
/// little-endian: the spec calls for network byte order on the whisper
/// channel — the payload is JSON text, so there is no native byte-order on
/// the payload side to keep consistent with. The capture protocol chose
/// little-endian because its payload is also little-endian Float32 samples
/// and matching them removes an end-of-stream confusion source there. Two
/// different protocols, two defensible defaults; the codec types are
/// distinct, so a reader/writer always knows which one it speaks.
///
/// `readFrame` / `writeFrame` wrap raw `read(2)` / `write(2)` with `EINTR`
/// retry — the same pattern as `CaptureSocketServer.writeAll`. They do not
/// set `SO_NOSIGPIPE` or `SO_SNDTIMEO` on the file descriptor; the caller
/// owning the socket configures those (see the subprocess and parent-side
/// client). On `EPIPE` (peer closed mid-write) the writer surfaces it as
/// `CodecError.writeFailed`.
public enum WhisperFrameCodec {

    /// Generous cap. ~30 s of 16 kHz mono Float32 (~1.9 MB) base64'd is
    /// ~2.6 MB; 8 MiB leaves headroom for future fields (token detail,
    /// VAD-region buffers) without inviting a runaway allocation if the
    /// header is corrupted. Sized to detect length-prefix corruption fast.
    public static let maxPayloadBytes: Int = 8 * 1024 * 1024

    public enum CodecError: Error, CustomStringConvertible, Equatable {
        /// A frame's declared length is bigger than `maxPayloadBytes`. The
        /// reader surfaces this on the header, the writer before sending.
        case payloadTooLarge(Int)
        /// `readFrame` got <4 bytes for the length prefix before EOF.
        /// (Clean EOF *before* any header byte returns `nil` instead — that
        /// is the peer disconnecting between frames, not mid-frame.)
        case truncatedHeader
        /// `readFrame` got the header but fewer payload bytes than declared
        /// before EOF.
        case truncatedPayload(expected: Int, got: Int)
        /// `read(2)` failed with a non-`EINTR` errno.
        case readFailed(errno: Int32)
        /// `write(2)` failed (`EPIPE`, timeout, etc.).
        case writeFailed(errno: Int32)

        public var description: String {
            switch self {
            case .payloadTooLarge(let n):
                return "whisper IPC frame payload \(n) bytes exceeds maximum"
            case .truncatedHeader:
                return "whisper IPC frame: truncated header"
            case .truncatedPayload(let expected, let got):
                return "whisper IPC frame: payload truncated, expected \(expected) bytes, got \(got)"
            case .readFailed(let e):
                return "whisper IPC read failed: errno \(e)"
            case .writeFailed(let e):
                return "whisper IPC write failed: errno \(e)"
            }
        }
    }

    /// Encode one frame's bytes: a 4-byte big-endian length followed by the
    /// JSON payload. Throws `.payloadTooLarge` if `jsonBytes.count` exceeds
    /// `maxPayloadBytes` — sending a giant frame can't be recovered from on
    /// the wire, so refuse it at the source.
    public static func encode(jsonBytes: Data) throws -> Data {
        guard jsonBytes.count <= maxPayloadBytes else {
            throw CodecError.payloadTooLarge(jsonBytes.count)
        }
        var out = Data(capacity: 4 + jsonBytes.count)
        var be = UInt32(jsonBytes.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(jsonBytes)
        return out
    }

    /// Decode one frame's payload from a buffer containing exactly one
    /// full frame (header + payload). Used in unit tests where a whole
    /// frame is constructed in memory; `readFrame` is the corresponding
    /// streaming reader.
    public static func decode(frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw CodecError.truncatedHeader }
        let length = Int(readBigEndianU32(frame))
        guard length <= maxPayloadBytes else {
            throw CodecError.payloadTooLarge(length)
        }
        let available = frame.count - 4
        guard available >= length else {
            throw CodecError.truncatedPayload(expected: length, got: available)
        }
        // Frames passed to `decode` should be exactly one frame; anything
        // beyond the declared length is silently ignored here — the reader
        // helper enforces tight framing on the wire.
        return frame.subdata(in: 4..<(4 + length))
    }

    /// Read exactly one frame from `fd`, retrying on `EINTR`. Returns the
    /// JSON payload bytes, or `nil` on a clean EOF *before* any header byte
    /// (peer closed between frames). Throws on a partial header / partial
    /// payload, on `read(2)` errors, and on an oversized declared length.
    public static func readFrame(from fd: Int32) throws -> Data? {
        var header = Data(count: 4)
        switch try readBytes(fd: fd, into: &header, count: 4) {
        case .ok:
            break
        case .eofBeforeAny:
            return nil
        case .eofMidway(let got):
            // We saw at least one byte of the header before EOF — that is
            // a mid-frame disconnect, distinct from a clean between-frames
            // close. Surface it so the caller can log "subprocess crashed".
            _ = got
            throw CodecError.truncatedHeader
        }
        let length = Int(readBigEndianU32(header))
        guard length <= maxPayloadBytes else {
            throw CodecError.payloadTooLarge(length)
        }
        guard length > 0 else {
            // A zero-length payload is a valid (if unusual) JSON-empty frame.
            // We return an empty Data; the decoder above will reject it.
            return Data()
        }
        var payload = Data(count: length)
        switch try readBytes(fd: fd, into: &payload, count: length) {
        case .ok:
            return payload
        case .eofBeforeAny:
            throw CodecError.truncatedPayload(expected: length, got: 0)
        case .eofMidway(let got):
            throw CodecError.truncatedPayload(expected: length, got: got)
        }
    }

    /// Write all of `frame` to `fd`, retrying on `EINTR`. The caller is
    /// responsible for `SO_NOSIGPIPE` on the socket so a vanished peer
    /// returns `EPIPE` to `write(2)` rather than killing the process.
    public static func writeFrame(_ frame: Data, to fd: Int32) throws {
        try frame.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CodecError.writeFailed(errno: errno)
                }
                if n == 0 {
                    // `write(2)` returning 0 on a stream socket is anomalous;
                    // treat it as a closed peer.
                    throw CodecError.writeFailed(errno: EPIPE)
                }
                offset += n
            }
        }
    }

    // MARK: - Internals

    private enum ReadResult {
        case ok
        case eofBeforeAny
        case eofMidway(got: Int)
    }

    /// Read exactly `count` bytes from `fd` into the first `count` bytes of
    /// `buffer`, retrying on `EINTR`. Reports whether EOF arrived before any
    /// byte, after some, or never (`ok`).
    private static func readBytes(
        fd: Int32, into buffer: inout Data, count: Int
    ) throws -> ReadResult {
        var got = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            while got < count {
                let n = read(fd, base + got, count - got)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CodecError.readFailed(errno: errno)
                }
                if n == 0 { return }   // EOF; `got` records how far we got
                got += n
            }
        }
        if got == count { return .ok }
        if got == 0 { return .eofBeforeAny }
        return .eofMidway(got: got)
    }

    /// Read a big-endian `UInt32` from the first 4 bytes of `data`.
    /// `data` must be at least 4 bytes; the caller has already checked.
    static func readBigEndianU32(_ data: Data) -> UInt32 {
        let bytes = Array(data.prefix(4))
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }
}
