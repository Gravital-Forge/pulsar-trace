import Foundation
import Logging

/// PT-P8-R3 (a) — passive owner-profile learning from ordinary (non-mic-
/// diarized) recordings: diarize the mic WAV, pick the cluster dominant over
/// the dedup-surviving mic segments, feed it to the inlier-gated store.
public enum OwnerProfileLearner {

    /// Pure selection: overlap of each cluster's spans with the surviving
    /// segments; dominant cluster's embedding, or nil.
    public static func ownerEmbedding(
        micDiarization: DiarizationResult,
        dedupedMicSegments: [TranscriptSegment]
    ) -> [Float]? {
        guard !dedupedMicSegments.isEmpty, !micDiarization.spans.isEmpty
        else { return nil }
        var overlapBySpeaker: [String: Double] = [:]
        for span in micDiarization.spans {
            for segment in dedupedMicSegments {
                let start = max(span.start, segment.start)
                let end = min(span.end, segment.end)
                if end > start {
                    overlapBySpeaker[span.speaker, default: 0]
                        += (end - start).seconds
                }
            }
        }
        guard let dominant = overlapBySpeaker.max(by: { $0.value < $1.value })?.key
        else { return nil }
        return micDiarization.embeddings
            .first { $0.speaker == dominant }?.vector
    }

    /// Full passive step used by both refine paths. Non-fatal by design:
    /// any failure logs and returns without touching refine output.
    public static func learn(
        micWav: URL,
        dedupedMicSegments: [TranscriptSegment],
        diarize: @Sendable (URL) async throws -> DiarizationResult,
        store: OwnerVoiceProfileStore,
        events: EventWriter?,
        logger: Logger
    ) async {
        do {
            let diarization = try await diarize(micWav)
            guard let embedding = ownerEmbedding(
                micDiarization: diarization,
                dedupedMicSegments: dedupedMicSegments)
            else { return }
            let outcome = try await store.update(
                embedding: embedding, modelRevision: diarization.modelRevision)
            if outcome != .rejectedOutlier {
                _ = try? await events?.append(OwnerProfileUpdatedEvent(
                    source: "passive_refine",
                    sampleCount: await store.snapshot()?.sampleCount ?? 0))
            }
        } catch {
            logger.warning("owner-profile passive learning skipped: \(error)")
        }
    }
}
