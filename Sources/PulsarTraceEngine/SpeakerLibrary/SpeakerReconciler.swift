import Foundation
import Logging

/// Reconciles a recording's post-pass diarization clusters against the
/// persistent speaker library (PT-R22, PT-R23, PT-R30).
///
/// After the diarizer produces a per-speaker embedding for a recording, the
/// refine pipeline asks the reconciler to map each raw cluster label
/// (`SPEAKER_00`, …) to a stable library speaker:
///
/// - a cluster whose centroid matches a library speaker (cosine ≥ threshold,
///   same `model_revision`) is **matched** — its library name is used
///   and the running-mean centroid is refined (PT-R30, `speaker_centroid_updated`);
/// - a cluster with no match becomes a **new** library speaker with an
///   `Unknown #N` placeholder name (`speaker_created`).
///
/// PT-P8-R5: mic-channel guest clusters reconcile here too; the owner cluster
/// is excluded via `excludingSpeakers` and is never in the library.
public struct SpeakerReconciler: Sendable {

    /// The reconciliation result for one recording.
    public struct Outcome: Sendable {
        /// Raw pyannote label → resolved library display name.
        public let nameByRawLabel: [String: String]
        /// Raw pyannote label → stable library speaker id (`spk_<ulid>`).
        public let speakerIdByRawLabel: [String: String]
        /// Count of clusters matched to an existing library speaker.
        public let matchedCount: Int
        /// Count of clusters that became new library speakers.
        public let newCount: Int
    }

    private let library: SpeakerLibrary
    private let threshold: Double
    private let logger: Logger

    public init(
        library: SpeakerLibrary,
        threshold: Double = SpeakerLibrary.defaultMatchThreshold,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.library = library
        self.threshold = threshold
        self.logger = logger
    }

    /// Reconcile one recording's diarization against the library.
    ///
    /// - Parameters:
    ///   - diarization: the recording's pyannote result (per-speaker embeddings).
    ///   - recordingId: the recording's stable id (`rec_<short>`).
    ///   - recordingFolderName: the recording folder basename (for the
    ///     retroactive `final.md` rewrite).
    ///   - excludingSpeakers: raw labels to skip entirely (PT-P8-R5) — the
    ///     mic-channel owner cluster is attributed to `You` and must never be
    ///     enrolled in the library.
    /// - Returns: the per-label name/id mapping the pipeline renders into
    ///   `final.md` and `metadata.json`.
    public func reconcile(
        diarization: DiarizationResult,
        recordingId: String,
        recordingFolderName: String,
        excludingSpeakers: Set<String> = []
    ) async throws -> Outcome {
        let revision = diarization.modelRevision
        let embeddingByLabel = Dictionary(
            diarization.embeddings.map { ($0.speaker, $0.vector) },
            uniquingKeysWith: { first, _ in first })

        var nameByRawLabel: [String: String] = [:]
        var speakerIdByRawLabel: [String: String] = [:]
        var matchedCount = 0
        var newCount = 0

        // Deterministic order: process raw labels sorted, so `Unknown #N`
        // numbering is stable across runs.
        for rawLabel in diarization.speakers.sorted() {
            // PT-P8-R5: the owner cluster (attributed to `You`) is excluded —
            // it must never be enrolled in the shared library.
            if excludingSpeakers.contains(rawLabel) { continue }
            guard let embedding = embeddingByLabel[rawLabel] else {
                // No embedding for this cluster — keep pyannote's display
                // label; it cannot be reconciled. Should not happen with a
                // healthy diarization result.
                let fallback = diarization.displayLabel(for: rawLabel)
                nameByRawLabel[rawLabel] = fallback
                logger.notice("reconcile: cluster has no embedding — keeping label")
                continue
            }

            if let match = try await library.bestMatch(
                for: embedding, modelRevision: revision, threshold: threshold) {
                // Returning speaker — use the library name, refine the centroid.
                let updated = try await library.recordAppearance(
                    speakerId: match.speaker.id,
                    centroid: embedding,
                    modelRevision: revision,
                    recordingId: recordingId,
                    recordingFolderName: recordingFolderName)
                nameByRawLabel[rawLabel] = updated.name
                speakerIdByRawLabel[rawLabel] = updated.id
                matchedCount += 1
            } else {
                // New speaker — `Unknown #N`, N counting all-time library size.
                let placeholder = try await Self.nextUnknownName(in: library)
                let created = try await library.createSpeaker(
                    name: placeholder,
                    centroid: embedding,
                    modelRevision: revision,
                    recordingId: recordingId,
                    recordingFolderName: recordingFolderName)
                nameByRawLabel[rawLabel] = created.name
                speakerIdByRawLabel[rawLabel] = created.id
                newCount += 1
            }
        }

        return Outcome(
            nameByRawLabel: nameByRawLabel,
            speakerIdByRawLabel: speakerIdByRawLabel,
            matchedCount: matchedCount,
            newCount: newCount)
    }

    /// The next `Unknown #N` placeholder name. `N` is one past the highest
    /// `Unknown #N` ever assigned in the library — across every live speaker,
    /// every soft-deleted speaker, and every delisted speaker, including those
    /// past the 30-day recovery window. The all-time scan (not just the
    /// recoverable window, SW2) is what makes a placeholder number genuinely
    /// never reused, even after a speaker has been hard-aged-out or delisted.
    ///
    /// `internal static` (PT-P8-R6): `SpeakerEditService.demoteOwner` mints an
    /// `Unknown #N` for the demoted owner and must share this one numbering
    /// scan — never duplicate it, or two mints could collide on a number.
    static func nextUnknownName(in library: SpeakerLibrary) async throws -> String {
        let live = try await library.liveSpeakers()
        let deleted = try await library.allDeletedSpeakers()
        let delisted = try await library.allDelistedSpeakers()
        var highest = 0
        for speaker in live + deleted + delisted {
            if let n = unknownNumber(in: speaker.name) {
                highest = max(highest, n)
            }
        }
        return "Unknown #\(highest + 1)"
    }

    /// Parse `N` out of an `Unknown #N` name, or `nil` if the name is not a
    /// placeholder.
    static func unknownNumber(in name: String) -> Int? {
        let prefix = "Unknown #"
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}
