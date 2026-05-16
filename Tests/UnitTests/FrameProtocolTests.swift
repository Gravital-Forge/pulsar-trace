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
}
