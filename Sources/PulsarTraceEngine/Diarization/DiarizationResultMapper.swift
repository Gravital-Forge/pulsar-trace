import Foundation

/// Maps FluidAudio's offline diarization output into the engine's
/// `DiarizationResult`. Pure — takes primitives, not FluidAudio types — so it
/// unit-tests without CoreML models and without the
/// `FluidAudio.DiarizationResult` name collision leaking past `DiarizerEngine`.
enum DiarizationResultMapper {

    /// The model id recorded in `DiarizationResult.model` /
    /// `metadata.json.diarization_model.id`.
    static let modelId = "FluidInference/speaker-diarization-coreml"

    /// One FluidAudio segment, reduced to primitives.
    struct Segment {
        let speakerId: String   // "S1", "S2", …
        let start: Double       // seconds
        let end: Double         // seconds
    }

    /// Build the engine-facing result.
    ///
    /// - `speakers` are natural-sorted ("S2" before "S10") so positional
    ///   `Speaker_N` display labels and the reconciler's deterministic
    ///   `Unknown #N` numbering stay stable past 9 speakers.
    /// - Embeddings are dropped when non-finite (defence mirroring the old
    ///   Python `_embeddings_by_label` NaN guard) or when their label has no
    ///   spans (an embedding nothing references is dead weight).
    static func map(
        segments: [Segment],
        speakerDatabase: [String: [Float]],
        audioDuration: Duration,
        modelRevision: String
    ) -> DiarizationResult {
        let labels = Set(segments.map(\.speakerId))
        let speakers = labels.sorted { naturalKey($0) < naturalKey($1) }
        let spans = segments
            .map {
                SpeakerSpan(
                    speaker: $0.speakerId,
                    start: duration($0.start),
                    end: duration($0.end))
            }
            .sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
        let embeddings = speakerDatabase
            .filter { labels.contains($0.key) }
            .filter { !$0.value.isEmpty && $0.value.allSatisfy(\.isFinite) }
            .map { SpeakerEmbedding(speaker: $0.key, vector: $0.value) }
            .sorted { $0.speaker < $1.speaker }
        return DiarizationResult(
            model: modelId,
            modelRevision: modelRevision,
            audioDuration: audioDuration,
            speakers: speakers,
            spans: spans,
            embeddings: embeddings)
    }

    /// Sort key making "S2" < "S10": the numeric suffix when present, else
    /// the label itself (labels FluidAudio doesn't emit today sort last,
    /// lexicographically).
    private static func naturalKey(_ label: String) -> (Int, String) {
        guard label.hasPrefix("S"), let n = Int(label.dropFirst()) else {
            return (Int.max, label)
        }
        return (n, label)
    }

    private static func duration(_ seconds: Double) -> Duration {
        .milliseconds(Int((seconds * 1000).rounded()))
    }
}
