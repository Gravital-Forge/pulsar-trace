import Testing
import Foundation
@testable import PulsarTraceEngine

/// Coverage of `WhisperLockProbe.waitUntilFree` — the recording-start
/// defence-in-depth check that the binary-level `whisper.lock` is free
/// before the engine subprocess tries to acquire it (Phase 6 / Layer B).
///
/// `WhisperLock` is the same primitive `pulsartrace-whisper` uses
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md` §4 Layer 2), so
/// holding one in-test simulates a refinement-whisper subprocess that
/// has not yet released its lock.
@Suite("WhisperLockProbe")
struct WhisperLockProbeTests {

    @Test("free lock → returns immediately")
    func freeLockReturnsImmediately() async throws {
        let path = Self.makeTempLockPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // No one holds the lock. The probe should succeed on its first
        // attempt and return without waiting near the timeout.
        let start = ContinuousClock.now
        try await WhisperLockProbe.waitUntilFree(
            lockPath: path, timeout: .seconds(2))
        let elapsed = ContinuousClock.now - start
        // Generous bound — even with scheduling jitter on a busy CI
        // machine, the synchronous flock acquire-and-release should be
        // well under a second.
        #expect(elapsed < .milliseconds(500))
    }

    @Test("lock still held past timeout → throws .timeout")
    func heldLockTimesOut() async throws {
        let path = Self.makeTempLockPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // Hold the lock for the entire test — the probe should never
        // acquire it and must throw `.timeout` after the deadline.
        let held = try WhisperLock(lockPath: path)
        defer { _ = held }   // keep it alive past the probe call

        let start = ContinuousClock.now
        do {
            try await WhisperLockProbe.waitUntilFree(
                lockPath: path,
                timeout: .milliseconds(400),
                pollInterval: .milliseconds(50))
            Issue.record("expected .timeout")
        } catch WhisperLockProbe.ProbeError.timeout {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let elapsed = ContinuousClock.now - start
        // The probe should have spent close to the timeout retrying
        // and NOT returned early.
        #expect(elapsed >= .milliseconds(300))
        // And shouldn't have wildly overshot the deadline.
        #expect(elapsed < .seconds(2))
    }

    @Test("lock released mid-poll → probe succeeds")
    func releasedMidPollSucceeds() async throws {
        let path = Self.makeTempLockPath()
        defer { try? FileManager.default.removeItem(at: path) }

        // Hold the lock initially in an actor-managed slot so a
        // concurrent task can drop it after a brief delay.
        actor LockHolder {
            var lock: WhisperLock?
            init(_ l: WhisperLock) { self.lock = l }
            func release() { lock = nil }
        }
        let holder = LockHolder(try WhisperLock(lockPath: path))

        // Concurrently release the lock 250 ms in. The probe is polling
        // at 100 ms so it will see the release on the next attempt.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            await holder.release()
        }

        let start = ContinuousClock.now
        try await WhisperLockProbe.waitUntilFree(
            lockPath: path,
            timeout: .seconds(2),
            pollInterval: .milliseconds(100))
        let elapsed = ContinuousClock.now - start
        // Should have waited at least until the release, not returned
        // immediately, and not blocked anywhere near the full timeout.
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
    }

    @Test("missing parent dir → throws .openFailed (no retry loop)")
    func missingParentThrowsOpenFailed() async {
        // A path under a parent directory that doesn't exist — `open(2)`
        // can't create the lock file. The probe must surface this
        // distinctly from `.timeout` so the caller's UI can be sensible.
        let bogus = URL(fileURLWithPath:
            "/tmp/whisper-lock-probe-\(UUID().uuidString)/missing-parent/lock")
        do {
            try await WhisperLockProbe.waitUntilFree(
                lockPath: bogus,
                timeout: .seconds(1))
            Issue.record("expected .openFailed")
        } catch WhisperLockProbe.ProbeError.openFailed(let e) {
            #expect(e != 0)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private static func makeTempLockPath() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-lock-probe-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).lock", isDirectory: false)
    }
}
