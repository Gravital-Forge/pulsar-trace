import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Identity verification for Unix-domain-socket peers.
///
/// Defense in depth on top of the 0700 socket directory: even a process
/// that reaches the socket path is only served if it runs as the same
/// user. `getpeereid(2)` reports the peer's *effective* uid as of
/// `connect(2)`; comparing against our own euid rejects any cross-user
/// connection without a round-trip.
public enum PeerCredentials {
    /// `true` iff the connected peer of `fd` runs as our effective uid.
    /// Any `getpeereid` failure (bad fd, not a socket, not connected)
    /// counts as a rejection.
    public static func peerIsSameUser(fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
    }
}
