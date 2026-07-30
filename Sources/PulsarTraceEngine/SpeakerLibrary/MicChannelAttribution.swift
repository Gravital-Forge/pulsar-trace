import Foundation
import Logging

/// PT-P8-R4/R5 — attribute mic clusters: at most one `You` (owner-profile
/// match, fail-safe), everyone else through the shared reconciler.
public enum MicChannelAttribution {

    public struct Outcome: Sendable {
        /// Raw label → display name; includes "You" for the owner cluster.
        public let nameByRawLabel: [String: String]
        /// Raw label → spk_ id; never contains the owner cluster.
        public let speakerIdByRawLabel: [String: String]
        /// The raw label attributed to the owner, nil when fail-safe fired.
        public let ownerRawLabel: String?
        public let matchedCount: Int
        public let newCount: Int

        public init(
            nameByRawLabel: [String: String],
            speakerIdByRawLabel: [String: String],
            ownerRawLabel: String?,
            matchedCount: Int,
            newCount: Int
        ) {
            self.nameByRawLabel = nameByRawLabel
            self.speakerIdByRawLabel = speakerIdByRawLabel
            self.ownerRawLabel = ownerRawLabel
            self.matchedCount = matchedCount
            self.newCount = newCount
        }
    }

    public static func attribute(
        micDiarization: DiarizationResult,
        ownerProfile: OwnerVoiceProfileStore?,
        library: SpeakerLibrary?,
        recordingId: String,
        recordingFolderName: String,
        events: EventWriter?,
        logger: Logger
    ) async throws -> Outcome {
        // 1. Owner match — best similarity at/above threshold (PT-P8-R4).
        //    `match` returns nil for an empty profile or a revision mismatch;
        //    that state is identical for every embedding this pass, so the very
        //    first nil is dispositive — there is no owner match at all. Breaking
        //    (vs. continuing) is therefore equivalent and cheaper.
        var ownerRawLabel: String?
        if let ownerProfile {
            var best: (label: String, similarity: Double)?
            for embedding in micDiarization.embeddings {
                guard let similarity = await ownerProfile.match(
                    embedding: embedding.vector,
                    modelRevision: micDiarization.modelRevision)
                else { break }   // empty or revision-mismatch: no owner match at all
                if similarity >= OwnerVoiceProfileStore.matchThreshold,
                   similarity > (best?.similarity ?? -1) {
                    best = (embedding.speaker, similarity)
                }
            }
            ownerRawLabel = best?.label
        }

        // PT-P8-R3 (b): the You cluster refines the profile.
        if let ownerRawLabel, let ownerProfile,
           let vector = micDiarization.embeddings
               .first(where: { $0.speaker == ownerRawLabel })?.vector {
            _ = try? await ownerProfile.update(
                embedding: vector, modelRevision: micDiarization.modelRevision)
            _ = try? await events?.append(OwnerProfileUpdatedEvent(
                source: "mic_diarized_refine",
                sampleCount: await ownerProfile.snapshot()?.sampleCount ?? 0))
        }

        // 2. Guests through the shared reconciler (PT-P8-R5); non-fatal on
        //    failure, same posture as the system stream.
        var names: [String: String] = [:]
        var ids: [String: String] = [:]
        var matched = 0
        var new = 0
        if let ownerRawLabel { names[ownerRawLabel] = "You" }
        if let library {
            do {
                let outcome = try await SpeakerReconciler(library: library)
                    .reconcile(
                        diarization: micDiarization,
                        recordingId: recordingId,
                        recordingFolderName: recordingFolderName,
                        excludingSpeakers: ownerRawLabel.map { [$0] } ?? [])
                names.merge(outcome.nameByRawLabel) { a, _ in a }
                ids = outcome.speakerIdByRawLabel
                matched = outcome.matchedCount
                new = outcome.newCount
            } catch {
                logger.error("mic reconciliation failed, raw labels kept: \(error)")
            }
        }
        return Outcome(
            nameByRawLabel: names, speakerIdByRawLabel: ids,
            ownerRawLabel: ownerRawLabel, matchedCount: matched, newCount: new)
    }
}
