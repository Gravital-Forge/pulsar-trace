import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `WhisperLock` — the structural single-instance
/// backstop (`docs/specs/2026-05-26-whisper-subprocess-design.md` §4
/// Layer 2). Two locks against the same path can't coexist; releasing
/// the first lets a new one acquire.
@Suite("WhisperLock")
struct WhisperLockTests {

    @Test("first acquire succeeds, second on same path throws .held")
    func secondAcquireFails() throws {
        let path = Self.makeTempLockPath()
        defer { try? FileManager.default.removeItem(at: path) }

        let first = try WhisperLock(lockPath: path)

        do {
            _ = try WhisperLock(lockPath: path)
            Issue.record("expected .held on second acquire")
        } catch WhisperLockError.held {
            // Expected — the kernel reports `EWOULDBLOCK` and we map
            // that to `.held` so the subprocess can exit 75 cleanly.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // Keep `first` alive until after the second-acquire attempt.
        _ = first
    }

    @Test("releasing the first lock lets a new one acquire")
    func releaseAllowsReAcquire() throws {
        let path = Self.makeTempLockPath()
        defer { try? FileManager.default.removeItem(at: path) }

        do {
            let first = try WhisperLock(lockPath: path)
            // The block scope releases `first` via ARC at its end; the
            // explicit `_ = first` keeps the compiler from hoisting the
            // release earlier.
            _ = first
        }
        // ARC released `first`; its `deinit` closed the fd and the
        // kernel released the `flock`. A new acquire should now succeed.
        let second = try WhisperLock(lockPath: path)
        _ = second
    }

    @Test("openFailed surfaces a sensible errno when parent dir is missing")
    func openFailedWhenParentMissing() {
        // A path under a directory that doesn't exist — `open(O_CREAT)`
        // can't create the file because the parent is missing.
        let missing = URL(fileURLWithPath:
            "/tmp/whisper-lock-tests-\(UUID().uuidString)/missing-parent/lock")
        do {
            _ = try WhisperLock(lockPath: missing)
            Issue.record("expected openFailed")
        } catch WhisperLockError.openFailed(let path, let errno) {
            #expect(path == missing.path)
            #expect(errno != 0)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    /// A unique path under `$TMPDIR` for one test's lock file. Each test
    /// uses its own path so cross-test runs (including the parallel
    /// runner) cannot collide with each other or with a real subprocess.
    private static func makeTempLockPath() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-lock-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).lock", isDirectory: false)
    }
}
