// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJob.swift
import Foundation

/// One queued refinement job. Persisted as JSON under
/// `~/Library/Application Support/PulsarTrace/refinement-queue/<id>.json`
/// (D-Q5) so a crash or quit resumes pending work on next launch.
///
/// The job descriptor is small and immutable apart from `state`. The actual
/// in-flight work — partial transcripts, completed VAD regions — lives in
/// `refine-progress.json` inside the recording folder, not here (D-Q5).
public struct RefinementJob: Codable, Equatable, Sendable, Identifiable {

    /// What triggered this job — informational, used by the UI badge.
    public enum Trigger: String, Codable, Sendable {
        case autoPostRecording      // RecordingViewModel.stopRecording → auto-enqueue
        case manual                 // Recordings list "Refine" button
        case crashRecovery          // RecordingViewModel.recoverFromCrash → auto-enqueue
    }

    public let id: String                  // ULID-derived (`job_<ulid>`).
    public let recordingId: String         // Stable id from RecordingFolder.recordingId.
    public let folderURL: URL              // The recording folder to refine.
    public let modelName: String           // Whisper model captured at enqueue (D-Q4).
    public let modelSHA256: String         // Captured for an audit-able metadata.json.
    public let trigger: Trigger
    public let enqueuedAt: Date
    public var state: RefinementJobState

    public init(
        id: String,
        recordingId: String,
        folderURL: URL,
        modelName: String,
        modelSHA256: String,
        trigger: Trigger,
        enqueuedAt: Date,
        state: RefinementJobState
    ) {
        self.id = id
        self.recordingId = recordingId
        self.folderURL = folderURL
        self.modelName = modelName
        self.modelSHA256 = modelSHA256
        self.trigger = trigger
        self.enqueuedAt = enqueuedAt
        self.state = state
    }
}
