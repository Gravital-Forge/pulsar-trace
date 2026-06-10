// Sources/PulsarTraceMenuBar/RefinementNotification.swift
import Foundation
import PulsarTraceEngine

/// User-facing notification content for a terminal refinement job.
/// Pure data — UN delivery lives at the call site so this stays testable
/// and the UserNotifications dependency stays bundle-guarded.
public struct RefinementNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let folderURL: URL

    /// Content for a terminal job, or `nil` when no notification is wanted
    /// (non-terminal states, and `.cancelled` — the user asked for that one).
    public static func from(job: RefinementJob) -> RefinementNotification? {
        switch job.state {
        case .completed(let durationSeconds, let speakerCount):
            let minutes = max(1, Int((durationSeconds / 60).rounded()))
            let speakers = speakerCount == 1 ? "1 speaker" : "\(speakerCount) speakers"
            return RefinementNotification(
                title: "Transcript ready",
                body: "\(speakers), \(minutes) min",
                folderURL: job.folderURL)
        case .failed:
            // Never surface the raw errorClass — it's a log/serialization
            // token, not user-facing copy.
            return RefinementNotification(
                title: "Refinement failed",
                body: "A recording could not be refined. Open PulsarTrace to retry.",
                folderURL: job.folderURL)
        case .queued, .running, .paused, .cancelled:
            return nil
        }
    }
}
