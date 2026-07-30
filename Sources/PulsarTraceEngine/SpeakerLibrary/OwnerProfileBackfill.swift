import Foundation
import Logging

/// PT-R137 (d) — one-shot owner-profile backfill, run when the global toggle
/// is first enabled (PT-R146) and no profile exists: existing recordings'
/// mic WAVs are known-owner audio (they were never mic-diarized).
public enum OwnerProfileBackfill {

    public struct Summary: Sendable, Equatable {
        public let foldersScanned: Int
        public let samplesAccepted: Int
    }

    /// Newest-first, bounded by `cap`; early exit once `stableRuns`
    /// consecutive accepted samples each move the centroid by < `epsilon`
    /// (cosine distance).
    public static let cap = 10
    public static let stableRuns = 3
    public static let epsilon = 0.01

    public static func run(
        outputRoots: [URL],
        store: OwnerVoiceProfileStore,
        diarize: @Sendable (URL) async throws -> DiarizationResult,
        events: EventWriter?,
        logger: Logger
    ) async throws -> Summary {
        let fm = FileManager.default
        // Candidate folders: hold a mic WAV, not stamped diarize_mic.
        var candidates: [(url: URL, mtime: Date)] = []
        for root in outputRoots {
            let children = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for child in children where child.hasDirectoryPath {
                let micWav = child.appendingPathComponent(
                    RecordingFolder.FileName.audioMic)
                guard fm.fileExists(atPath: micWav.path),
                      !RecordingOptions.read(from: child).diarizeMic
                else { continue }
                let mtime = (try? child.resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((child, mtime))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }   // newest first

        var scanned = 0
        var accepted = 0
        var stableStreak = 0
        for candidate in candidates.prefix(Self.cap) {
            scanned += 1
            let micWav = candidate.url.appendingPathComponent(
                RecordingFolder.FileName.audioMic)
            do {
                let diarization = try await diarize(micWav)
                // No transcript here — the whole mic stream of a non-diarized
                // recording is owner audio; dominant cluster by span time.
                var timeBySpeaker: [String: Double] = [:]
                for span in diarization.spans {
                    timeBySpeaker[span.speaker, default: 0]
                        += (span.end - span.start).seconds
                }
                guard let dominant = timeBySpeaker
                    .max(by: { $0.value < $1.value })?.key,
                      let embedding = diarization.embeddings
                    .first(where: { $0.speaker == dominant })?.vector
                else { continue }

                let before = await store.snapshot()?.centroid
                let outcome = try await store.update(
                    embedding: embedding,
                    modelRevision: diarization.modelRevision)
                guard outcome == .seeded || outcome == .accepted else { continue }
                accepted += 1
                if let before, let after = await store.snapshot()?.centroid {
                    let movement = 1 - Centroid.cosineSimilarity(before, after)
                    stableStreak = movement < Self.epsilon ? stableStreak + 1 : 0
                    if stableStreak >= Self.stableRuns { break }
                }
            } catch {
                logger.warning("backfill skipped \(candidate.url.lastPathComponent): \(error)")
            }
        }
        if accepted > 0 {
            _ = try? await events?.append(OwnerProfileUpdatedEvent(
                source: "backfill",
                sampleCount: await store.snapshot()?.sampleCount ?? 0))
        }
        return Summary(foldersScanned: scanned, samplesAccepted: accepted)
    }
}
