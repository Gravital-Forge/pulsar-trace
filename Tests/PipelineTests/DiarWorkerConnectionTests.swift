import Testing
import Foundation
@testable import PulsarTraceEngine
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Suite("DiarWorkerConnection over a socketpair")
struct DiarWorkerConnectionTests {
    /// Returns two connected fds via socketpair(AF_UNIX, SOCK_STREAM).
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, sockStreamType, 0, &fds)
        #expect(rc == 0)
        return (fds[0], fds[1])
    }

    @Test("frames written on one end arrive whole on the other, in order")
    func framesRoundTrip() async throws {
        let (a, b) = pair()
        let writer = DiarWorkerConnection(fd: a)
        let reader = DiarWorkerConnection(fd: b)

        let f1 = DiarWorkerProtocol.encodeRequest(requestId: 1, samples: [1, 2])
        let f2 = DiarWorkerProtocol.encodeRequest(requestId: 2, samples: [3])
        try writer.send(f1)
        try writer.send(f2)

        var bodies: [Data] = []
        for await body in reader.inboundBodies {
            bodies.append(body)
            if bodies.count == 2 { break }
        }
        #expect(try DiarWorkerProtocol.decodeRequest(bodies[0]).requestId == 1)
        #expect(try DiarWorkerProtocol.decodeRequest(bodies[1]).requestId == 2)
        writer.close()
        reader.close()
    }

    @Test("closing the peer ends the inbound stream")
    func peerCloseEndsStream() async throws {
        let (a, b) = pair()
        let writer = DiarWorkerConnection(fd: a)
        let reader = DiarWorkerConnection(fd: b)
        writer.close()                 // peer hangs up
        var count = 0
        for await _ in reader.inboundBodies { count += 1 }
        #expect(count == 0)            // stream finishes, loop exits
        reader.close()
    }
}
