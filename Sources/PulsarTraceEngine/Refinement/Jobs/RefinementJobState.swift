// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobState.swift
import Foundation

/// One job's lifecycle in the queue.
///
/// Lifecycle: `.queued` → `.running` → (`.paused`?) → `.completed` | `.failed` | `.cancelled`.
/// A job can move from `.running` to `.paused` and back any number of times
/// (e.g. each time a recording starts mid-refine); `.cancelled` is terminal.
public enum RefinementJobState: Codable, Equatable, Sendable {

    /// One stage of the refine pipeline. Matches `RefinementPipeline.Stage`
    /// 1:1 so a progress reporter can map between them.
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case resolvingInput
        case transcribingSystem
        case diarizing
        case transcribingMic
        case merging
        case writingFinal
        case writingMetadata

        /// Human-readable label for the UI (1-3 words). The `rawValue` is for
        /// logging/serialization — never show it to end users.
        public var displayName: String {
            switch self {
            case .resolvingInput:      return "Loading audio"
            case .transcribingSystem:  return "Transcribing system"
            case .diarizing:           return "Diarizing"
            case .transcribingMic:     return "Transcribing mic"
            case .merging:             return "Merging"
            case .writingFinal:        return "Writing transcript"
            case .writingMetadata:     return "Writing metadata"
            }
        }
    }

    /// Why the queue paused this job.
    public enum PauseReason: String, Codable, Sendable {
        case userRequested
        case recordingInProgress

        /// Human-readable label for the UI. The `rawValue` is for
        /// logging/serialization — never show it to end users.
        public var displayName: String {
            switch self {
            case .userRequested:        return "User paused"
            case .recordingInProgress:  return "Recording in progress"
            }
        }
    }

    case queued
    case running(stage: Stage, stepsCompleted: Int, stepsTotal: Int,
                 regionIndex: Int?, regionsTotal: Int?)
    case paused(reason: PauseReason, lastStage: Stage)
    case completed(durationSeconds: Double, speakerCount: Int)
    case failed(errorClass: String, retryAvailable: Bool)
    case cancelled

    /// Fraction in `0...1` if the queue can estimate progress, else `nil`.
    ///
    /// The estimate weights each completed stage as `1/stepsTotal` and within
    /// the running stage scales by `regionIndex/regionsTotal` when whisper
    /// is running, otherwise by 0.5 (single-shot stages like diarization
    /// report half-credit while in flight — not 0, not 1).
    public var progressFraction: Double? {
        switch self {
        case .queued, .cancelled, .failed: return nil
        case .completed: return 1.0
        case .paused: return nil
        case .running(_, let done, let total, let regionIdx, let regionsTotal):
            guard total > 0 else { return nil }
            let base = Double(done) / Double(total)
            let perStage = 1.0 / Double(total)
            if let regionIdx, let regionsTotal, regionsTotal > 0 {
                return base + perStage * Double(regionIdx) / Double(regionsTotal)
            }
            return base + perStage * 0.5
        }
    }
}
