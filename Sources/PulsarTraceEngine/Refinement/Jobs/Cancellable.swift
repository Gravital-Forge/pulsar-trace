import Foundation

/// One-method seam the queue uses to terminate an inflight worker on pause
/// (D-Q7). `Diarizer` is the production conformer; tests inject a spy.
///
/// Note: a conformer's `cancel()` may return before the underlying work is
/// fully torn down. `Diarizer.cancel()` sends SIGTERM and schedules a 500 ms
/// SIGKILL escalation, but returns immediately — the subprocess may still be
/// alive on return. The queue does not wait for the subprocess to die; the
/// refiner's cancel-retry loop handles the eventual
/// `DiarizeError.cancelled` thrown by the next `diarizeSystemStream` call.
public protocol RefinementCancellable: Sendable {
    func cancel() async
}
