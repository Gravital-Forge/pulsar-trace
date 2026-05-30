import Foundation

/// Exponential-backoff schedule for the "waiting for whisper subprocess
/// respawn" log line
/// (`docs/specs/2026-05-26-whisper-subprocess-design.md` §6).
///
/// The 2026-05-26 wedge produced ~3,948 "did not honor abort" lines in
/// 3:36 — a 50 ms-tight poll-and-log pattern. The replacement here is a
/// state machine that doubles each emission's delay (5 s → 10 s → 20 s
/// → 40 s → 80 s → 160 s → 320 s, capped at 600 s) so a long stall
/// produces a finite, greppable trail rather than a log flood.
///
/// `nextDelay()` returns the duration to sleep *before* the next log
/// line; the caller emits the log after waking. `reset()` restores the
/// initial interval — used when the respawn completes so the next
/// stall starts fresh, not at the previous cap.
///
/// Value-semantic on purpose: a `RemoteWindowTranscriber`'s respawn
/// loop holds one of these as a local, so a brand-new stall (after a
/// long-lived host that finally needed a respawn) is not stuck at the
/// 600 s cap from a previous stall.
struct RespawnLogThrottle {
    /// The delay the next `nextDelay()` call will return.
    var nextInterval: Duration
    /// Doubling cap. Past this, every emission is at the cap.
    let cap: Duration
    /// Constructor-time initial; `reset()` returns to this. Captured so
    /// `reset` is "back to the start of this instance's schedule", not
    /// "back to a process-wide default" — a test that wires up a 10 ms
    /// initial gets that 10 ms initial back when it resets.
    private let initial: Duration

    /// Default schedule: starts at 5 s, caps at 600 s — the constants
    /// the spec calls out. Callers in production use this initializer;
    /// tests parameterize for shorter (and faster) backoff trails.
    init(initial: Duration = .seconds(5), cap: Duration = .seconds(600)) {
        self.nextInterval = initial
        self.cap = cap
        self.initial = initial
    }

    /// Return the current interval, then double the next one (capped).
    /// Doubling-after-return means the very first log line happens
    /// after `initial`, the next after `initial * 2`, etc., matching
    /// the 5/10/20/40 schedule in §6.
    mutating func nextDelay() -> Duration {
        let d = nextInterval
        nextInterval = min(nextInterval * 2, cap)
        return d
    }

    /// Restore the initial interval. Called after a successful respawn
    /// so a subsequent stall does not start at the previous cap.
    mutating func reset() {
        nextInterval = initial
    }
}
