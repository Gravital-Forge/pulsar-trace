import Testing
import Foundation
@testable import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Unit coverage of `WhisperFrameCodec` — the big-endian-length JSON
/// framing the `pulsartrace-whisper` subprocess speaks
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md` §5).
@Suite("WhisperFrameCodec")
struct WhisperFrameCodecTests {

    @Test("encode then decode round-trips a JSON payload")
    func encodeDecodeRoundTrip() throws {
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let frame = try WhisperFrameCodec.encode(jsonBytes: payload)

        // 4-byte big-endian length + payload.
        #expect(frame.count == 4 + payload.count)
        let length = WhisperFrameCodec.readBigEndianU32(frame)
        #expect(Int(length) == payload.count)

        let decoded = try WhisperFrameCodec.decode(frame: frame)
        #expect(decoded == payload)
    }

    @Test("encode rejects an oversized payload up front")
    func encodeOversizedRejected() {
        let huge = Data(count: WhisperFrameCodec.maxPayloadBytes + 1)
        #expect(throws: WhisperFrameCodec.CodecError.payloadTooLarge(huge.count)) {
            _ = try WhisperFrameCodec.encode(jsonBytes: huge)
        }
    }

    @Test("decode rejects a truncated header")
    func decodeTruncatedHeader() {
        #expect(throws: WhisperFrameCodec.CodecError.truncatedHeader) {
            _ = try WhisperFrameCodec.decode(frame: Data([0x00, 0x00, 0x00]))
        }
    }

    @Test("decode rejects a payload shorter than its declared length")
    func decodeTruncatedPayload() {
        // length=4 in big-endian, then only 2 bytes of payload.
        let bytes = Data([0x00, 0x00, 0x00, 0x04, 0xAA, 0xBB])
        do {
            _ = try WhisperFrameCodec.decode(frame: bytes)
            Issue.record("expected truncatedPayload")
        } catch let e as WhisperFrameCodec.CodecError {
            #expect(e == .truncatedPayload(expected: 4, got: 2))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("decode rejects a header that declares an oversized payload")
    func decodeOversizedDeclaration() {
        // length = maxPayloadBytes + 1, big-endian.
        let len = UInt32(WhisperFrameCodec.maxPayloadBytes + 1)
        var header = Data()
        var be = len.bigEndian
        withUnsafeBytes(of: &be) { header.append(contentsOf: $0) }
        #expect(throws: WhisperFrameCodec.CodecError.payloadTooLarge(Int(len))) {
            _ = try WhisperFrameCodec.decode(frame: header)
        }
    }

    @Test("readFrame returns nil on a clean EOF before the header")
    func readFrameCleanEOF() throws {
        let (r, w) = try Self.makePipe()
        close(w)   // writer closes immediately — reader sees EOF
        defer { close(r) }
        let result = try WhisperFrameCodec.readFrame(from: r)
        #expect(result == nil)
    }

    @Test("readFrame throws on a partial header before EOF")
    func readFrameTruncatedHeader() throws {
        let (r, w) = try Self.makePipe()
        // Write 2 bytes (header is 4) then close.
        let two: [UInt8] = [0x00, 0x00]
        _ = two.withUnsafeBufferPointer { buf in
            write(w, buf.baseAddress, buf.count)
        }
        close(w)
        defer { close(r) }
        #expect(throws: WhisperFrameCodec.CodecError.truncatedHeader) {
            _ = try WhisperFrameCodec.readFrame(from: r)
        }
    }

    @Test("readFrame throws on a partial payload before EOF")
    func readFrameTruncatedPayload() throws {
        let (r, w) = try Self.makePipe()
        // Header declares length=4, then writer sends only 1 byte and closes.
        let length: UInt32 = 4
        var be = length.bigEndian
        var header = Data()
        withUnsafeBytes(of: &be) { header.append(contentsOf: $0) }
        header.append(0xAA)
        _ = header.withUnsafeBytes { raw -> Int in
            write(w, raw.baseAddress, raw.count)
        }
        close(w)
        defer { close(r) }
        do {
            _ = try WhisperFrameCodec.readFrame(from: r)
            Issue.record("expected truncatedPayload")
        } catch let e as WhisperFrameCodec.CodecError {
            #expect(e == .truncatedPayload(expected: 4, got: 1))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("readFrame reads one frame at a time from a multi-frame stream")
    func readFrameMultiFrameStream() throws {
        let (r, w) = try Self.makePipe()
        defer { close(r) }
        let p1 = Data(#"{"a":1}"#.utf8)
        let p2 = Data(#"{"b":2}"#.utf8)
        let frame1 = try WhisperFrameCodec.encode(jsonBytes: p1)
        let frame2 = try WhisperFrameCodec.encode(jsonBytes: p2)
        let combined = frame1 + frame2
        _ = combined.withUnsafeBytes { raw -> Int in
            write(w, raw.baseAddress, raw.count)
        }
        close(w)
        let got1 = try WhisperFrameCodec.readFrame(from: r)
        let got2 = try WhisperFrameCodec.readFrame(from: r)
        let got3 = try WhisperFrameCodec.readFrame(from: r)
        #expect(got1 == p1)
        #expect(got2 == p2)
        #expect(got3 == nil)   // clean EOF after both frames
    }

    @Test("writeFrame writes the full encoded frame to a pipe")
    func writeFrameRoundTripsThroughPipe() throws {
        let (r, w) = try Self.makePipe()
        defer { close(r) }

        let payload = Data(#"{"x":42}"#.utf8)
        let frame = try WhisperFrameCodec.encode(jsonBytes: payload)
        try WhisperFrameCodec.writeFrame(frame, to: w)
        close(w)
        let read = try WhisperFrameCodec.readFrame(from: r)
        #expect(read == payload)
    }

    // MARK: - Helpers

    /// Create a POSIX pipe; returns (read fd, write fd). Used by the
    /// codec tests so we can exercise `read(2)` / `write(2)` semantics
    /// (EOF, partial reads, EINTR retry) end-to-end without needing a
    /// real UDS.
    private static func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        let r = fds.withUnsafeMutableBufferPointer { buf in
            pipe(buf.baseAddress)
        }
        guard r == 0 else {
            throw POSIXError(.EIO)
        }
        return (fds[0], fds[1])
    }
}
