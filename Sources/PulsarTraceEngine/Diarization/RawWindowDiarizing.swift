import Foundation

/// The narrow seam `LiveDiarizer` drives raw per-window diarization through.
/// The production conformer is `DiarizerEngineRawAdapter`, which runs the
/// FluidAudio diarizer in-process over the shared `DiarizerEngine` actor; a
/// test conformer can be an in-process fake.
///
/// Stateless by contract: it diarizes ONE window of samples and returns the
/// raw, window-local spans + embeddings. All cross-window stitching (stable
/// `Them #N` keys, running centroids) lives in `LiveDiarizer`, so the seam
/// carries no cross-window identity state.
public protocol RawWindowDiarizing: Sendable {
    /// Diarize one window of 16 kHz mono Float32 samples. Returns `nil` when no
    /// usable result is available (a diarizer hiccup) — the live pass then
    /// degrades for that window, never crashes.
    func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult?

    /// The diarization model's content digest, for the R18 speaker-library
    /// revision scoping. Empty string when unknown (degrades safely).
    func modelRevision() async -> String
}
