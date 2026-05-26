import Foundation
import Logging

/// Diagnostic-only phase tracker for `LiveRunner.run`'s frame loop.
///
/// The run loop calls `set(_:frameIndex:)` synchronously at every step — before
/// each `await`, before each significant synchronous block — so the tracker
/// always holds the most recent phase and the wall-clock instant it was
/// entered. A background heartbeat task (started via `runHeartbeat`) wakes on
/// a fixed cadence and logs a warning whenever the current phase has been
/// active longer than `threshold` — making a wedged `await` observable as a
/// stream of identical log lines with a monotonically growing `age`.
///
/// Lock-protected (not actor) so `set` is non-suspending and can never become
/// the wedge it is diagnosing: holding `NSLock` for two stored-property writes
/// cannot deadlock against the run loop's own awaits.
///
/// Diagnostic only — does not recover, does not cancel, does not change run
/// loop behavior. Removing the calls to `set` would leave run loop semantics
/// unchanged.
public final class LiveRunnerPhaseTracker: @unchecked Sendable {

    /// A point-in-time read of the tracker. `since` is the wall-clock instant
    /// the current phase was entered; subtract from `Date()` for the age.
    public struct Snapshot: Sendable {
        public let phase: String
        public let frameIndex: Int
        public let since: Date
    }

    private let lock = NSLock()
    private var _phase: String = "init"
    private var _frameIndex: Int = 0
    private var _since: Date = Date()

    public init() {}

    /// Update the current phase and reset `since` to now. `frameIndex` is
    /// updated only when a value is provided so a phase change inside the same
    /// frame keeps the frame index sticky — the heartbeat then reports the
    /// frame the wedge is on, not the frame before the last `await`.
    public func set(_ phase: String, frameIndex: Int? = nil) {
        lock.withLock {
            _phase = phase
            _since = Date()
            if let frameIndex { _frameIndex = frameIndex }
        }
    }

    /// Atomic read of phase + frame index + since-timestamp.
    public func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(phase: _phase, frameIndex: _frameIndex, since: _since)
        }
    }

    /// Wake every `interval` and log a warning whenever the current phase has
    /// been active longer than `threshold`. Quiet on a healthy run loop (phase
    /// flips faster than `threshold`); a wedge yields one warning per tick
    /// with the same phase/frameIndex and a growing age.
    ///
    /// Caller owns the task and cancels it to stop the heartbeat.
    public func runHeartbeat(
        interval: Duration,
        threshold: Duration,
        logger: Logger
    ) async {
        let thresholdSeconds = Self.seconds(threshold)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                break
            }
            let snap = snapshot()
            let age = Date().timeIntervalSince(snap.since)
            if age >= thresholdSeconds {
                let ageMs = Int((age * 1000).rounded())
                logger.warning(
                    "LiveRunner phase=\(snap.phase) age=\(ageMs)ms frameIdx=\(snap.frameIndex)")
            }
        }
    }

    /// A `Duration` as fractional seconds. Same pattern used elsewhere in the
    /// codebase (e.g. `DeviceCaptureSource.secondsValue`).
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let c = duration.components
        return TimeInterval(c.seconds)
            + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
