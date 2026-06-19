import Foundation

/// Bounds the outstanding live-diarization work to a single window in flight
/// (Fix B), and **reclaims a wedged slot** so one hung window cannot freeze
/// diarization for the rest of the recording (D42).
///
/// The run loop dispatches each due diarization window to a detached task so a
/// wedged diarizer cannot stall transcription or `live.md`. `tryAcquire()`
/// grants the single in-flight slot; the detached task `release(_:)`s when it
/// finishes. A window that cannot acquire is simply skipped — live diarization
/// is best-effort/provisional and the post-pass is the source of truth.
///
/// ## Wedge reclaim (D42)
///
/// A live diarization window normally finishes in ~0.2 s. If one wedges — e.g. a
/// synchronous CoreML/ANE `prediction` that hangs, which is **deaf to `Task`
/// cancellation**, so the slot would otherwise never be released — every later
/// window is skipped and live diarization dies for the rest of the recording
/// (the system stream then collapses to a single speaker via the `?? "Them"`
/// label fallback). `tryAcquire()` therefore force-reclaims a slot that has been
/// held at least `reclaimAfter`: the wedged task is abandoned (left to leak) and
/// the slot is granted to the new window.
///
/// Reclaim is made safe with a **generation token**: `tryAcquire()` returns the
/// holder's token and `release(_:)` frees the slot only if the token still
/// matches the current holder. The abandoned wedged task's eventual
/// `release(staleToken)` is then a no-op, so it cannot free a slot a later
/// window now owns.
actor DiarGate {

    /// The outcome of a `tryAcquire()`.
    enum Acquisition: Sendable, Equatable {
        /// The slot was free; granted with this token.
        case granted(Int)
        /// A wedged holder (held ≥ `reclaimAfter`) was force-reclaimed and the
        /// new window granted with this token. Distinct from `granted` so the
        /// caller can log it — it means a live diarization window hung.
        case reclaimed(Int)
        /// A window is in flight and has not yet aged out; skip this window.
        case busy

        /// The grant token, or `nil` when busy.
        var token: Int? {
            switch self {
            case .granted(let t), .reclaimed(let t): return t
            case .busy: return nil
            }
        }
    }

    private var inFlight = false
    private var holder = 0
    private var acquiredAt: ContinuousClock.Instant?
    private let reclaimAfter: Duration

    /// - Parameter reclaimAfter: how long a slot may be held before its holder
    ///   is presumed wedged and the slot is force-reclaimed. Defaults to 2 s —
    ///   an order of magnitude above the ~0.2 s a healthy window takes.
    init(reclaimAfter: Duration = .seconds(2)) {
        self.reclaimAfter = reclaimAfter
    }

    /// Take the single in-flight slot. The caller must pass the returned token
    /// to `release(_:)`. `.busy` means a window is already in flight and has not
    /// aged out — skip this window.
    func tryAcquire() -> Acquisition {
        var reclaimed = false
        if inFlight {
            guard let at = acquiredAt,
                ContinuousClock.now - at >= reclaimAfter
            else { return .busy }
            // The holder has exceeded the deadline — presume it wedged, abandon
            // it, and fall through to grant the slot to this window.
            reclaimed = true
        }
        holder += 1
        inFlight = true
        acquiredAt = ContinuousClock.now
        return reclaimed ? .reclaimed(holder) : .granted(holder)
    }

    /// Release the in-flight slot — but only if `token` still matches the
    /// current holder, so a reclaimed (abandoned) window's late release cannot
    /// free a newer holder's slot.
    func release(_ token: Int) {
        guard inFlight, token == holder else { return }
        inFlight = false
        acquiredAt = nil
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
