import Foundation

/// The single decode operation the live streaming path depends on.
///
/// Extracted as a protocol so the live pipeline can be driven by a test
/// double (a slow or hanging stub) without a real model.
/// `ParakeetWindowTranscriber` is the production conformer.
///
/// Not `Sendable`: a conformer is driven from one task/queue at a time.
public protocol WindowTranscribing: AnyObject {
    /// Decode one streaming window. Implementations bound their own decode
    /// time (e.g. `ParakeetWindowTranscriber`'s 30 s deadline) — a wedged
    /// window throws and is skipped; the post-pass recovers the audio.
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: TranscriptionOptions
    ) throws -> TranscriptionResult
}
