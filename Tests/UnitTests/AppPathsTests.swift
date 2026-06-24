import Testing
import Foundation
@testable import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Unit coverage of `AppPaths` location resolution (including the capture
/// socket paths).
@Suite("AppPaths")
struct AppPathsTests {

    private let paths = AppPaths(home: URL(fileURLWithPath: "/tmp/pt-home"))

    @Test("Socket directory resolves under NSTemporaryDirectory / PulsarTrace")
    func socketDirectoryLocation() {
        let socketDir = paths.socketDirectory
        // `socketDirectory` is decoupled from `home` — it lives under
        // `$TMPDIR/PulsarTrace/` so the absolute path length is bounded
        // by the OS-controlled `$TMPDIR` (~47 bytes on Darwin) rather
        // than by the user's home directory depth.
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(),
                          isDirectory: true)
            .standardizedFileURL.path
        let socketRoot = socketDir
            .deletingLastPathComponent()
            .standardizedFileURL.path
        #expect(socketRoot == tmpRoot)
        #expect(socketDir.lastPathComponent == "PulsarTrace")
    }

    @Test("Per-recording socket URLs are distinct and carry the recording id")
    func perRecordingSocketURLs() {
        let system = paths.systemSocketURL(recordingId: "rec_4f2a")
        let mic = paths.micSocketURL(recordingId: "rec_4f2a")
        #expect(system.lastPathComponent == "rec_4f2a-system.sock")
        #expect(mic.lastPathComponent == "rec_4f2a-mic.sock")
        #expect(system != mic)
        #expect(system.deletingLastPathComponent() == paths.socketDirectory)
    }

    /// `sockaddr_un.sun_path` on Darwin — recomputed here so the test
    /// asserts against the real OS-level constant, not a duplicated
    /// number that could drift.
    private static let sunPathCapacity: Int =
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    @Test("Longest realistic socket filenames fit under sun_path on the standard layout")
    func socketURLsFitSunPath() {
        // Guards against the 2026-05-27 production bug recurring: with the
        // old socket directory (`~/Library/Application Support/PulsarTrace/
        // sockets/`), a long username (or any extra path depth) pushed the
        // capture and whisper socket paths past `sockaddr_un.sun_path`'s
        // 104-byte Darwin cap, manifesting as a misleading
        // `handshakeTimedOut`. By rooting `socketDirectory` under
        // `$TMPDIR/PulsarTrace/` (~60 bytes on the test box, constant
        // regardless of username) we keep ~40+ bytes of headroom for the
        // longest filenames in the code today.
        let standard = AppPaths.standard
        let capacity = Self.sunPathCapacity

        // Representative recording id: `rec_<timestamp>` as emitted by
        // `RecordingId.now()` is ~21 chars.
        let recordingId = "rec_2026-05-27-104641"
        let systemSocket = standard.systemSocketURL(recordingId: recordingId)
        let micSocket = standard.micSocketURL(recordingId: recordingId)
        let systemBytes = systemSocket.path.utf8.count
        let micBytes = micSocket.path.utf8.count
        #expect(systemBytes < capacity,
                "systemSocketURL overflows sun_path: \(systemBytes) >= \(capacity) — \(systemSocket.path)")
        #expect(micBytes < capacity,
                "micSocketURL overflows sun_path: \(micBytes) >= \(capacity) — \(micSocket.path)")

        // The whisper subprocess socket: `w-<8hex>.sock` (15 bytes)
        // appended to `socketDirectory`.
        let whisperSocket = standard.socketDirectory
            .appendingPathComponent("w-deadbeef.sock", isDirectory: false)
        let whisperBytes = whisperSocket.path.utf8.count
        #expect(whisperBytes < capacity,
                "whisper subprocess socket overflows sun_path: \(whisperBytes) >= \(capacity) — \(whisperSocket.path)")
    }

    @Test("socketDirectory does NOT live under the home root")
    func socketDirectoryIndependentOfHome() {
        // Regression guard: if someone tries to "fix" `socketDirectory`
        // back to use `applicationSupport` (which is rooted at `home`),
        // this test catches it. The whole point of moving sockets to
        // `$TMPDIR` was to bound the path length by the OS-controlled
        // `$TMPDIR`, *not* by the user's username length.
        let longHomeComponents = String(repeating: "/x", count: 40) // 80 bytes
        let longHome = URL(fileURLWithPath: longHomeComponents)
        let pathsWithLongHome = AppPaths(home: longHome)
        let socketPath = pathsWithLongHome.socketDirectory.path
        #expect(!socketPath.contains(longHomeComponents),
                "socketDirectory must be independent of `home`; got: \(socketPath)")
        #expect(!socketPath.contains("Application Support"),
                "socketDirectory must not live under Application Support; got: \(socketPath)")
    }
}
