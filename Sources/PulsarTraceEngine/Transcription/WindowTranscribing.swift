import Foundation

/// The single decode operation the live streaming path depends on.
///
/// Extracted as a protocol so the live pipeline can be driven by a test double
/// (a slow, hanging, or abort-honoring stub) without a real CoreML model.
/// `ParakeetWindowTranscriber` is the production conformer (D39).
///
/// Not `Sendable`: a real conformer drives a resident model that must be
/// touched from one task/queue at a time.
public protocol WindowTranscribing: AnyObject {
    /// Decode one streaming window. `abort`, when non-nil, lets a watchdog
    /// interrupt a hung/runaway decode (see `AbortToken`); `nil` disables it.
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperOptions,
        abort: AbortToken?
    ) throws -> TranscriptionResult
}
