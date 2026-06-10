import Foundation

/// Bounds the outstanding live-diarization work to a single window in flight
/// (Fix B).
///
/// The run loop dispatches each due diarization window to a detached task so a
/// wedged diarizer subprocess cannot stall transcription or `live.md`. Without
/// a bound, a slow diarizer would let detached tasks (and their captured window
/// samples) pile up unboundedly. `DiarGate` is the bound: `tryAcquire()`
/// succeeds only when no window is in flight; the detached task `release()`s
/// when it finishes. A window that cannot acquire is simply skipped — live
/// diarization is best-effort/provisional and the post-pass is the source of
/// truth.
actor DiarGate {
    private var inFlight = false

    /// Take the single in-flight slot. `true` → caller owns it and must
    /// eventually `release()`; `false` → a window is already in flight, skip.
    func tryAcquire() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    /// Release the in-flight slot (called by the detached diar task on finish).
    func release() { inFlight = false }

    /// At end of run, wait — bounded by `timeout` — for any in-flight window to
    /// finish so a detached diar task does not outlive the run. A wedged
    /// diarizer simply times out here; the run still returns.
    ///
    /// The poll loop is cancellation-aware: `Task.isCancelled` is part of the
    /// loop condition, so a cancelled task exits promptly instead of swallowing
    /// the `CancellationError` from `Task.sleep` and spinning to the deadline.
    func drain(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while inFlight && ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
