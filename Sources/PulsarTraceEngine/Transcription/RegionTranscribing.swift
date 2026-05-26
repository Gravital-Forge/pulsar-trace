import Foundation

/// The single decode operation the refinement pass depends on.
///
/// Sibling to `WindowTranscribing`; used by the refinement path. A test double
/// or a remote IPC client (future Phase 5) can stand in for the real
/// `WhisperTranscriber`.
///
/// Not `Sendable`: a real conformer owns a non-`Sendable` `whisper_context` and
/// must be driven from one task/queue at a time.
public protocol RegionTranscribing: AnyObject {
    /// Decode one VAD region. Segment timestamps come back on the recording
    /// timeline (i.e. shifted by the region's start), matching the contract
    /// of `WhisperTranscriber.transcribeRegion(_:region:options:)`.
    func transcribeRegion(
        _ samples: [Float],
        region: SpeechRegion,
        options: WhisperOptions
    ) throws -> TranscriptionResult
}
