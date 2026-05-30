import Testing
import Foundation
@testable import PulsarTraceEngine

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Coverage for the `sockaddr_un.sun_path` length guard added to
/// `WhisperSubprocessHost.startAndInitialize`.
///
/// Background: macOS's `sockaddr_un.sun_path` is 104 bytes (incl. NUL).
/// In production the socket directory is
/// `~/Library/Application Support/PulsarTrace/sockets/` (~63 bytes).
/// Before the guard, a long filename made `bind(2)` fail in the
/// subprocess, which then exited; the parent's handshake reader saw EOF
/// before the termination handler latched `exitStatus`, and surfaced
/// the misleading `handshakeTimedOut`.
///
/// These tests do not spawn a real subprocess: the precondition fires
/// before `Process.run()` so a benign placeholder binary (e.g.
/// `/usr/bin/true`) is sufficient. Real spawn + bind + handshake is
/// covered by the Phase 7 acceptance suite.
@Suite("WhisperSubprocessHost path-length guard")
struct WhisperSubprocessHostPathLengthTests {

    /// `sockaddr_un.sun_path` on Darwin — recomputed here so the test
    /// asserts against the real OS-level constant, not a duplicated
    /// number that could drift.
    private static let sunPathCapacity: Int =
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Resolve a "an executable that exists" path for `binaryURL`. The
    /// guard fires before exec, so this binary is never actually run by
    /// these tests; we just need `FileManager.isExecutableFile` to say
    /// yes so we get past the `binaryNotFound` check.
    private static func benignBinaryURL() throws -> URL {
        let candidates = ["/usr/bin/true", "/bin/true"]
        for path in candidates
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw HarnessError.noTrueAvailable
    }

    private enum HarnessError: Error { case noTrueAvailable }

    @Test("startAndInitialize throws spawnFailed when the socket path is too long")
    func longSocketDirectoryThrowsSpawnFailed() throws {
        let binaryURL = try Self.benignBinaryURL()

        // Build a tempdir whose full path (incl. our short filename
        // `w-XXXXXXXX.sock` = 15 bytes) overflows the 104-byte limit.
        // We pad a real, creatable directory under TMPDIR.
        let tmpBase = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true)
        // 15 bytes for the minted filename plus 1 byte for the path
        // separator the URL machinery inserts between dir and filename.
        let filenameOverhead = "/w-XXXXXXXX.sock".utf8.count // = 16
        let baseLen = tmpBase.path.utf8.count
        // Make sure the directory path alone, plus the filename
        // overhead, exceeds the capacity by a comfortable margin.
        let needed = Self.sunPathCapacity - baseLen - filenameOverhead + 16
        // Pad with a single long segment of `a`s — file systems on
        // macOS allow 255-byte filename components, so this is fine.
        let padCount = max(needed, 1)
        let padded = tmpBase.appendingPathComponent(
            String(repeating: "a", count: padCount),
            isDirectory: true)

        let config = WhisperSubprocessHost.Configuration(
            binaryURL: binaryURL,
            socketDirectory: padded)
        let host = WhisperSubprocessHost(
            configuration: config,
            logger: .init(label: "test"))

        do {
            try host.startAndInitialize(model: "/tmp/fake-model")
            Issue.record("expected throw")
        } catch WhisperSubprocessHost.HostError.spawnFailed(let message) {
            #expect(message.contains("socket path too long"),
                    "expected 'socket path too long' in: \(message)")
            // Also assert the byte count appears, so debug output is
            // self-explaining.
            #expect(message.contains("bytes"),
                    "expected byte count in: \(message)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The host must not have a running subprocess — guard fires
        // before `Process.run()`.
        #expect(host.isAlive == false)
        #expect(host.exitStatus == nil)

        // Cleanup the long-padded directory we created.
        try? FileManager.default.removeItem(at: padded)
    }

    @Test("short socket directory yields a path under the sun_path limit")
    func shortSocketDirectoryFitsUnderLimit() {
        // Construct a short, realistic socket directory and verify the
        // *would-be* minted filename pattern fits comfortably under the
        // limit. The host's filename is `w-<8-hex>.sock` = 15 bytes; we
        // simulate the same construction here to assert the structural
        // contract without spawning anything.
        let shortDir = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        let shortID = UUID().uuidString.prefix(8)
        let candidate = shortDir
            .appendingPathComponent("w-\(shortID).sock", isDirectory: false)

        // 15 bytes filename + tmp dir + separator + 8-hex segment.
        // Compute the total and assert it is strictly less than the
        // sun_path capacity (which is 104 on Darwin).
        let total = candidate.path.utf8.count
        #expect(total < Self.sunPathCapacity,
                "expected \(total) < \(Self.sunPathCapacity)")
        // And sanity-check the minted filename itself is 15 bytes.
        let lastComponent = candidate.lastPathComponent
        #expect(lastComponent.utf8.count == 15,
                "expected 15-byte filename, got \(lastComponent.utf8.count): \(lastComponent)")
        #expect(lastComponent.hasPrefix("w-"))
        #expect(lastComponent.hasSuffix(".sock"))
    }

    @Test("the production-style socket directory still fits the new filename")
    func productionSocketDirectoryFitsUnderLimit() {
        // Recreate the production path shape (~/Library/Application
        // Support/PulsarTrace/sockets/) using a typical-length home
        // directory and assert the minted path stays under the limit.
        // We don't hit the real home; we just want the byte budget to
        // be auditable.
        let typicalHome = URL(
            fileURLWithPath: "/Users/mateusz", isDirectory: true)
        let socketDir = typicalHome
            .appendingPathComponent(
                "Library/Application Support/PulsarTrace/sockets",
                isDirectory: true)
        let socketPath = socketDir.appendingPathComponent(
            "w-deadbeef.sock", isDirectory: false)
        let bytes = socketPath.path.utf8.count
        // Production case in the bug report: 63 + 15 = 78 bytes.
        #expect(bytes < Self.sunPathCapacity,
                "production socket path is \(bytes) bytes; need < \(Self.sunPathCapacity)")
    }
}
