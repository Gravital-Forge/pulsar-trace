import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the `capture.sock` binary frame protocol codec (R76).
@Suite("FrameProtocol")
struct FrameProtocolTests {

    @Test("Encode then decode round-trips a frame's samples")
    func roundTrip() throws {
        let samples: [Float] = (0..<320).map { Float($0) / 320.0 }
        let frame = AudioFrame(samples: samples, sequenceIndex: 3)
        let wire = FrameProtocol.encode(frame)

        // First 4 bytes are the little-endian payload length.
        #expect(wire.count == 4 + 320 * 4)
        let payload = wire.dropFirst(4)
        let decoded = try FrameProtocol.decodePayload(Data(payload))
        #expect(decoded == samples)
    }

    @Test("End-of-stream sentinel is a zero length prefix")
    func endOfStreamSentinel() {
        let eos = FrameProtocol.encodeEndOfStream()
        #expect(eos == Data([0, 0, 0, 0]))
    }

    @Test("Misaligned payload is rejected")
    func misalignedPayloadRejected() {
        #expect(throws: FrameProtocol.FrameError.self) {
            _ = try FrameProtocol.decodePayload(Data([1, 2, 3]))
        }
    }

    @Test("Oversized payload is rejected")
    func oversizedPayloadRejected() {
        let huge = Data(count: FrameProtocol.maxPayloadBytes + 4)
        #expect(throws: FrameProtocol.FrameError.self) {
            _ = try FrameProtocol.decodePayload(huge)
        }
    }

    // MARK: - Control frames (pause/resume)

    @Test("Paused control frame round-trips through length + payload")
    func pausedControlFrame() throws {
        let wire = FrameProtocol.encodeStreamPaused()
        // 4-byte length prefix == 1, then a 1-byte opcode payload.
        #expect(wire.count == 5)
        let length = wire.prefix(4).withUnsafeBytes { raw -> UInt32 in
            let b = raw.bindMemory(to: UInt8.self)
            return UInt32(b[0]) | (UInt32(b[1]) << 8)
                | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        }
        #expect(length == 1)
        #expect(FrameProtocol.isControlLength(length))
        #expect(try FrameProtocol.decodeControl(Data(wire.dropFirst(4))) == .paused)
    }

    @Test("Resumed control frame round-trips its gap nanoseconds")
    func resumedControlFrame() throws {
        let gap: UInt64 = 5_250_000_000  // 5.25 s
        let wire = FrameProtocol.encodeStreamResumed(gapNanoseconds: gap)
        // 4-byte length prefix == 9, then opcode + 8-byte little-endian gap.
        #expect(wire.count == 13)
        let length = wire.prefix(4).withUnsafeBytes { raw -> UInt32 in
            let b = raw.bindMemory(to: UInt8.self)
            return UInt32(b[0]) | (UInt32(b[1]) << 8)
                | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        }
        #expect(length == 9)
        #expect(FrameProtocol.isControlLength(length))
        #expect(
            try FrameProtocol.decodeControl(Data(wire.dropFirst(4)))
                == .resumed(gapNanoseconds: gap))
    }

    @Test("A Float32-aligned length is not a control frame")
    func frameLengthsAreNotControl() {
        #expect(!FrameProtocol.isControlLength(0))     // end-of-stream
        #expect(!FrameProtocol.isControlLength(1280))  // a 20 ms frame
        #expect(FrameProtocol.isControlLength(1))      // paused
        #expect(FrameProtocol.isControlLength(9))      // resumed
    }

    @Test("An unrecognized control opcode is rejected")
    func unknownControlFrameRejected() {
        #expect(throws: FrameProtocol.FrameError.self) {
            _ = try FrameProtocol.decodeControl(Data([0xFF]))
        }
    }
}
