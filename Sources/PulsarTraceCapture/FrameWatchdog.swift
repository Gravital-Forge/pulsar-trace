import Foundation

/// Detects a *silently stalled* capture stream: a `SCStream` or
/// `AVCaptureSession` that stops delivering buffers with no error and no
/// end-of-stream. Capture engines `arm()` it when capture starts and call
/// `notifyFrame()` on every delivered frame; if no frame arrives within
/// `threshold`, the watchdog fires `onStall` exactly once.
///
/// Backed by a `DispatchSourceTimer` on a private serial queue. `disarm()`
/// drains that queue (`queue.sync {}`) before returning, mirroring
/// `SleepWakeMonitor.stop()` — so the watchdog cannot fire after `disarm()`
/// returns even if the timer was about to.
final class FrameWatchdog: @unchecked Sendable {

    /// Invoked once, on the watchdog's private queue, when no frame has
    /// arrived within `threshold` of arming or of the last `notifyFrame()`.
    var onStall: (@Sendable () -> Void)?

    private let threshold: Duration
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// Latched once the watchdog has fired or been disarmed; the timer handler
    /// re-checks it so a fire already dequeued before `disarm()` is suppressed.
    private var done = false

    /// - Parameters:
    ///   - threshold: max silence before a stall is declared.
    ///   - label: dispatch-queue label (distinguishes the system/mic watchdogs).
    init(threshold: Duration, label: String) {
        self.threshold = threshold
        self.queue = DispatchQueue(label: label)
    }

    /// Start (or restart) the countdown. Safe to call repeatedly; each call
    /// replaces any prior timer. A no-op once the watchdog has fired or been
    /// disarmed.
    func arm() {
        lock.withLock {
            guard !done else { return }
            schedule_locked()
        }
    }

    /// Reset the countdown — call on every delivered frame. A no-op once the
    /// watchdog has fired or been disarmed (so a frame racing teardown cannot
    /// resurrect the timer).
    func notifyFrame() {
        lock.withLock {
            guard !done, timer != nil else { return }
            schedule_locked()
        }
    }

    /// Stop the watchdog permanently and drain its queue so a fire already
    /// dequeued cannot run after this returns. Idempotent. Must not be called
    /// from the watchdog's own queue.
    func disarm() {
        let pending: DispatchSourceTimer? = lock.withLock {
            done = true
            let t = timer
            timer = nil
            return t
        }
        pending?.cancel()
        // Drain any handler already dequeued before `done` was latched.
        queue.sync {}
    }

    /// Whole-nanosecond deadline; clamped at zero.
    private func thresholdNanos() -> UInt64 { threshold.wholeNanoseconds }

    /// Caller holds `lock`. Cancel any existing timer and arm a fresh one.
    private func schedule_locked() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let nanos = thresholdNanos()
        t.schedule(deadline: .now() + .nanoseconds(Int(nanos)))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let fire: (@Sendable () -> Void)? = self.lock.withLock {
                guard !self.done else { return nil }
                self.done = true
                self.timer = nil
                return self.onStall
            }
            fire?()
        }
        timer = t
        t.resume()
    }
}
