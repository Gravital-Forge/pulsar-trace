import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("DiarWorker wire DTO")
struct DiarWindowResultCodableTests {
    @Test("DiarWindowResult round-trips through JSON")
    func resultRoundTrips() throws {
        let r = DiarWindowResult(
            spans: [.init(speaker: "S1", startMillis: 0, endMillis: 1500),
                    .init(speaker: "S2", startMillis: 1500, endMillis: 3000)],
            embeddings: [.init(speaker: "S1", vector: [0.1, 0.2, 0.3]),
                         .init(speaker: "S2", vector: [0.4, 0.5, 0.6])])
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(DiarWindowResult.self, from: data)
        #expect(decoded == r)
    }

    @Test("DiarWorkerMessage round-trips both cases")
    func messageRoundTrips() throws {
        let hello = DiarWorkerMessage.hello(modelRevision: "abc123")
        let result = DiarWorkerMessage.result(
            requestId: 42,
            window: DiarWindowResult(spans: [], embeddings: []))
        for m in [hello, result] {
            let data = try JSONEncoder().encode(m)
            #expect(try JSONDecoder().decode(DiarWorkerMessage.self, from: data) == m)
        }
    }
}

@Suite("DiarWorker frame codec")
struct DiarWorkerFrameTests {
    @Test("request frame round-trips requestId + samples")
    func requestFrameRoundTrips() throws {
        let samples: [Float] = [0.0, -1.0, 0.5, 0.25]
        let frame = DiarWorkerProtocol.encodeRequest(requestId: 7, samples: samples)
        // 4-byte length prefix + 8-byte id + 4*4 sample bytes
        #expect(frame.count == 4 + 8 + 16)
        let (len, body) = try DiarWorkerProtocol.splitLengthPrefixed(frame)
        #expect(len == 8 + 16)
        let decoded = try DiarWorkerProtocol.decodeRequest(body)
        #expect(decoded.requestId == 7)
        #expect(decoded.samples == samples)
    }

    @Test("message frame round-trips a result envelope")
    func messageFrameRoundTrips() throws {
        let msg = DiarWorkerMessage.result(
            requestId: 9,
            window: DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 10)],
                                     embeddings: []))
        let frame = try DiarWorkerProtocol.encodeMessage(msg)
        let (_, body) = try DiarWorkerProtocol.splitLengthPrefixed(frame)
        #expect(try DiarWorkerProtocol.decodeMessage(body) == msg)
    }

    @Test("a truncated length prefix is reported, not crashed")
    func truncatedPrefixThrows() {
        #expect(throws: (any Error).self) {
            _ = try DiarWorkerProtocol.splitLengthPrefixed(Data([0x01, 0x02]))
        }
    }
}
