import Foundation

/// The recording state machine the menubar drives (PT-R40, PT-R45).
///
/// `RecordingViewModel` owns one of these and transitions it as the
/// capture+engine subprocess pair starts, runs, and tears down. The menubar
/// icon and menu are pure functions of this value. Post-recording refinement
/// runs asynchronously on the `RefinementJobQueue` — the recording state
/// machine returns to `.idle` immediately after stop, allowing back-to-back
/// meetings without waiting for refine to complete.
///
/// State flow (happy path): `.idle` → `.launching` → `.recording` → `.idle`.
/// An unexpected engine exit while `.recording` moves to `.crashed` (PT-R45);
/// a launch failure to `.error`.
public enum RecordingStatus: Equatable, Sendable {
    /// No recording in progress — the menubar is ready to start one.
    case idle
    /// `startRecording()` is spawning the capture+engine pair (PT-R40).
    case launching
    /// A recording is running. `id` is the `rec_<short>` id; `startedAt`
    /// drives the menubar's elapsed-time display.
    case recording(id: String, startedAt: Date)
    /// The engine exited unexpectedly mid-recording (PT-R45). `partialFolderURL`
    /// is the recording folder whose partial `live.md` can still be refined.
    case crashed(id: String, partialFolderURL: URL?)
    /// A launch / start failure that is not a crash — carries a user-facing
    /// message (e.g. a missing TCC permission).
    case error(message: String)

    /// Whether a new recording may be started from this state — only `.idle`.
    public var canStartRecording: Bool {
        if case .idle = self { return true }
        return false
    }

    /// Whether a recording can be stopped from this state.
    public var canStopRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Whether the engine subprocess pair is live in this state.
    public var isActive: Bool {
        switch self {
        case .launching, .recording: return true
        case .idle, .crashed, .error: return false
        }
    }
}
