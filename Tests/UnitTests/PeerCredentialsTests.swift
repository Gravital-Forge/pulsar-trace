import Foundation
import Testing
@testable import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `getpeereid`-based same-user verification for UDS peers.
@Suite("PeerCredentials")
struct PeerCredentialsTests {

    @Test("a socketpair peer in the same process is the same user")
    func socketpairIsSameUser() throws {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        // #require, not #expect: if socketpair failed, the deferred
        // close(fds[0])/close(fds[1]) would close fd 0/1 (stdin/stdout).
        try #require(rc == 0)
        defer { close(fds[0]); close(fds[1]) }

        #expect(PeerCredentials.peerIsSameUser(fd: fds[0]))
        #expect(PeerCredentials.peerIsSameUser(fd: fds[1]))
    }

    @Test("an invalid fd is rejected")
    func invalidFDRejected() {
        #expect(!PeerCredentials.peerIsSameUser(fd: -1))
    }

    @Test("a non-socket fd is rejected")
    func nonSocketFDRejected() {
        let devnull = open("/dev/null", O_RDONLY)
        #expect(devnull >= 0)
        defer { close(devnull) }
        #expect(!PeerCredentials.peerIsSameUser(fd: devnull))
    }
}
