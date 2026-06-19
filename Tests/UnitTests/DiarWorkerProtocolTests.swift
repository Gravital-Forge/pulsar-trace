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
