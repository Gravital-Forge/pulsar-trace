import Testing
import Foundation
@testable import PulsarTraceEngine
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A fake launcher backed by a socketpair + an in-process worker task whose
/// "hang" behaviour is scriptable. Each `launch()` makes a fresh pair and a
/// fresh worker; `kill` cancels the worker task and closes its end (modelling
/// SIGKILL → the worker's ANE work is "released"). Tracks launch/kill counts.
actor FakeWorkerLauncher: DiarWorkerLaunching {
    enum Behaviour: Sendable { case respond; case hang }
    private var behaviours: [Behaviour]          // one per launch, consumed in order
    private(set) var launches = 0
    private(set) var kills = 0
    init(_ behaviours: [Behaviour]) { self.behaviours = behaviours }

    func launch() async throws -> DiarWorkerHandle {
        launches += 1
        let behaviour = behaviours.isEmpty ? .respond : behaviours.removeFirst()
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, sockStreamType, 0, &fds)
        let engineConn = DiarWorkerConnection(fd: fds[0])
        let workerConn = DiarWorkerConnection(fd: fds[1])
        // In-process fake worker: hello, then echo a result per request unless hanging.
        let worker = Task {
            try? workerConn.send(try DiarWorkerProtocol.encodeMessage(.hello(modelRevision: "rev")))
            for await body in workerConn.inboundBodies {
                guard behaviour == .respond,
                      let req = try? DiarWorkerProtocol.decodeRequest(body) else { continue }
                let result = DiarWorkerMessage.result(
                    requestId: req.requestId,
                    window: DiarWindowResult(spans: [.init(speaker: "S1", startMillis: 0, endMillis: 1)],
                                             embeddings: []))
                try? workerConn.send(try DiarWorkerProtocol.encodeMessage(result))
            }
        }
        return DiarWorkerHandle(
            connection: engineConn,
            modelRevision: "rev",
            kill: { [weak self] in worker.cancel(); workerConn.close(); engineConn.close()
                    Task { await self?.bumpKills() } },
            awaitExit: { _ = await worker.result })
    }
    func bumpKills() { kills += 1 }
}

@Suite("DiarWorkerClient supervisor", .serialized)
struct DiarWorkerClientTests {
    @Test("a normal window returns the worker's result")
    func normalRPC() async throws {
        let launcher = FakeWorkerLauncher([.respond])
        let client = DiarWorkerClient(launcher: launcher, deadline: .milliseconds(500), restartBackoff: .zero)
        await client.start()
        let r = await client.diarizeRawWindow(samples: [0, 0, 0])
        #expect(r?.spans.first?.speaker == "S1")
        #expect(await client.modelRevision() == "rev")
        await client.shutdown()
    }

    @Test("a hung worker hits the deadline, is killed, and the NEXT window recovers")
    func hangThenRecover() async throws {
        // Launch 1 hangs; launch 2 (after kill+respawn) responds.
        let launcher = FakeWorkerLauncher([.hang, .respond])
        let client = DiarWorkerClient(launcher: launcher, deadline: .milliseconds(200), restartBackoff: .zero)
        await client.start()

        let first = await client.diarizeRawWindow(samples: [0])     // hangs → deadline → nil
        #expect(first == nil)
        #expect(await launcher.kills >= 1)                          // the hung worker was killed

        // Give the async respawn a moment, then a fresh window must succeed.
        try await Task.sleep(for: .milliseconds(300))
        let second = await client.diarizeRawWindow(samples: [0])
        #expect(second?.spans.first?.speaker == "S1")
        #expect(await launcher.launches >= 2)                       // respawned
        await client.shutdown()
    }
}
