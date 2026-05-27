import Foundation

/// Defence-in-depth probe used at recording-start time to confirm the
/// binary-level `whisper.lock` (`WhisperLock`, spec §4 Layer 2) is free
/// before the engine subprocess spawns its own `pulsartrace-whisper`.
///
/// The mac-app calls `pauseForRecording` *first*, which terminates the
/// refinement-whisper subprocess (Phase 6, Layer A). In normal operation
/// the lock is released by the time `pauseForRecording` returns. This
/// probe catches the rare cases where the kernel-side release is slow,
/// the subprocess teardown is fighting an unresponsive read, or a Layer
/// A signalling bug left a stale subprocess running. Without it, those
/// cases surface as the silent `exit 75` mode where the engine subprocess
/// dies during model load and the recording fails with a generic
/// model-load-failed error.
///
/// The probe is *not* the lifecycle owner — it does not hold the lock.
/// It acquires the lock, immediately releases it, and returns. Production
/// callers wait until the probe returns cleanly, then proceed to
/// `orchestrator.start()`. There is a microscopic TOCTOU window between
/// "the probe released" and "the engine subprocess acquires" — that is
/// acceptable: another acquirer in that window would only ever be the
/// engine's own subprocess (Layer A guarantees the refinement subprocess
/// has exited by this point).
public enum WhisperLockProbe {

    /// `waitUntilFree` outcome — the probe either confirmed the lock is
    /// free (and immediately released its probe acquire) or hit `timeout`
    /// with the lock still held by another process.
    public enum ProbeError: Error, CustomStringConvertible, Equatable {
        /// Lock was still held by another process after `timeout` elapsed.
        case timeout
        /// `open(2)` failed for a reason other than "another process holds
        /// the lock" — typically a missing parent directory or permission
        /// denied. The caller surfaces this distinctly from `.timeout`.
        case openFailed(errno: Int32)

        public var description: String {
            switch self {
            case .timeout: return "whisper lock still held after timeout"
            case .openFailed(let e): return "whisper lock open failed: errno \(e)"
            }
        }
    }

    /// Try to acquire the `whisper.lock` at `lockPath`; on success release
    /// immediately. If `EWOULDBLOCK`, sleep `pollInterval` and retry until
    /// `timeout` elapses.
    ///
    /// Returns normally on success — the lock is free at the moment the
    /// probe acquired it. Throws `.timeout` if still held past the
    /// deadline; throws `.openFailed` if the underlying open(2) call
    /// fails for a structural reason (e.g. missing parent directory).
    ///
    /// - Parameters:
    ///   - lockPath: same path as the subprocess uses
    ///     (`~/Library/Application Support/PulsarTrace/whisper.lock` in
    ///     production; tests inject a temp path).
    ///   - timeout: total time to wait before giving up.
    ///   - pollInterval: gap between retry attempts. 100 ms in production
    ///     — small enough to feel snappy on the happy path, large enough
    ///     that the wakeup pressure on the kernel is negligible.
    public static func waitUntilFree(
        lockPath: URL,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(100)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            do {
                // Acquire-and-immediately-release: the local
                // `WhisperLock` binding falls out of scope at the end of
                // this `do` block, ARC closes the fd, the kernel
                // releases the flock. Synchronous and immediate; no
                // sleep needed between acquire and release.
                let probe = try WhisperLock(lockPath: lockPath)
                _ = probe
                return
            } catch WhisperLockError.held {
                // Another process holds it — sleep and retry.
                if ContinuousClock.now >= deadline {
                    throw ProbeError.timeout
                }
                // If the next poll would land past the deadline, clamp
                // the sleep so we still detect the timeout at the
                // intended moment instead of overshooting by up to a
                // full poll interval.
                let remaining = deadline - ContinuousClock.now
                let sleepFor = remaining < pollInterval ? remaining : pollInterval
                do {
                    try await Task.sleep(for: sleepFor)
                } catch {
                    // Cancelled — caller is no longer waiting. Surface
                    // as timeout (the lock is, from the caller's POV,
                    // still held when they stopped caring).
                    throw ProbeError.timeout
                }
            } catch WhisperLockError.openFailed(_, let errnoVal) {
                // Structural failure — don't retry-loop on a missing
                // directory or permission-denied. Surface so the
                // caller can present a sensible UI error.
                throw ProbeError.openFailed(errno: errnoVal)
            }
        }
    }
}
