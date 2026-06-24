import Foundation

/// Bounds the outstanding live-diarization work to a single window in flight
/// (Fix B): a slow or wedged diarizer is kept off the run loop's critical path
/// so it can never stall transcription or `live.md`.
///
/// The run loop dispatches each due diarization window to a detached task and
/// uses this gate to keep at most one of them in flight. `tryAcquire()` grants
/// the single slot when it is free; the detached task `release()`s when it
/// finishes. A window that cannot acquire is simply skipped — live diarization
/// is best-effort/provisional and the post-pass is the source of truth, so
/// dropping a window while a slower one is still running costs nothing.
actor DiarGate {

    private var inFlight = false

    init() {}

    /// Take the single in-flight slot. Returns `true` and claims the slot when
    /// it is free; returns `false` when a window is already in flight, meaning
    /// the caller should skip this window.
    func tryAcquire() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    /// Release the in-flight slot, freeing it for the next window.
    func release() {
        inFlight = false
    }

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
