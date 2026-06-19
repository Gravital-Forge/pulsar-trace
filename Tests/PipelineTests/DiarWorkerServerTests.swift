import Testing
import Foundation
@testable import PulsarTraceEngine
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Local copy (PipelineTests can't see the UnitTests one): a RawWindowDiarizing
/// fake returning a scripted result per call.
actor ScriptedRawDiarizer: RawWindowDiarizing {
    private var queue: [DiarWindowResult?]
    let revision: String
    init(_ queue: [DiarWindowResult?], revision: String = "rev") {
        self.queue = queue
        self.revision = revision
    }
    func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
    func modelRevision() async -> String { revision }
}

@Suite("DiarWorkerServer loop")
struct DiarWorkerServerTests {
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, sockStreamType, 0, &fds)
        return (fds[0], fds[1])
    }

    @Test("server sends hello then a result per request")
    func helloThenResults() async throws {
        let (engineFd, workerFd) = pair()
        let engine = DiarWorkerConnection(fd: engineFd)
        let workerConn = DiarWorkerConnection(fd: workerFd)

        let scripted = ScriptedRawDiarizer(
            [DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 5)],
                              embeddings: [.init(speaker: "S1", vector: [0.5])])],
            revision: "rev-1")
        let server = DiarWorkerServer(connection: workerConn, rawDiarizer: scripted)
        let serverTask = Task { await server.run() }

        // Send one request.
        try engine.send(DiarWorkerProtocol.encodeRequest(requestId: 11, samples: [0, 0, 0]))

        var got: [DiarWorkerMessage] = []
        for await body in engine.inboundBodies {
            got.append(try DiarWorkerProtocol.decodeMessage(body))
            if got.count == 2 { break }
        }
        #expect(got[0] == .hello(modelRevision: "rev-1"))
        #expect(got[1] == .result(
            requestId: 11,
            window: DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 5)],
                                     embeddings: [.init(speaker: "S1", vector: [0.5])])))
        serverTask.cancel()
        engine.close(); workerConn.close()
    }
}
