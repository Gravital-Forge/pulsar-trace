import Testing
import Foundation
@testable import PulsarTraceEngine
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A DiarWorkerConnecting spy that records close() and lets the test drive
/// inbound frames + a scripted hello/result, so we can assert the supervisor
/// closes the connection (C1: no leaked engine-side fd).
final class SpyConnection: DiarWorkerConnecting, @unchecked Sendable {
    let inboundBodies: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var _closeCount = 0
    var closeCount: Int { lock.withLock { _closeCount } }
    init() {
        var c: AsyncStream<Data>.Continuation!
        self.inboundBodies = AsyncStream { c = $0 }
        self.cont = c
    }
    func send(_ frame: Data) throws {
        // Echo a result for any request so diarizeRawWindow resolves.
        if let req = try? DiarWorkerProtocol.decodeRequest(frame.dropFirst(4)) {
            let msg = DiarWorkerMessage.result(requestId: req.requestId,
                window: DiarWindowResult(spans: [], embeddings: []))
            if let f = try? DiarWorkerProtocol.encodeMessage(msg),
               let (_, body) = try? DiarWorkerProtocol.splitLengthPrefixed(f) {
                cont.yield(body)
            }
        }
    }
    func close() { lock.withLock { _closeCount += 1 }; cont.finish() }
}

actor SpyLauncher: DiarWorkerLaunching {
    let conn = SpyConnection()
    func launch() async throws -> DiarWorkerHandle {
        DiarWorkerHandle(connection: conn, modelRevision: "rev",
                         kill: {}, awaitExit: {})
    }
}

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

    @Test("shutdown closes the worker connection (C1: no leaked fd)")
    func shutdownClosesConnection() async {
        let launcher = SpyLauncher()
        let client = DiarWorkerClient(launcher: launcher, deadline: .seconds(5), restartBackoff: .zero)
        await client.start()
        _ = await client.diarizeRawWindow(samples: [0])   // exercises a normal round-trip
        await client.shutdown()
        #expect(await launcher.conn.closeCount >= 1)       // FAILS before the fix
    }
}
