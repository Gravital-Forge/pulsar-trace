import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `SpeakerReconciler` — the bridge between a recording's
/// diarization clusters and the persistent library (R22, R23).
@Suite("Speaker reconciler")
struct SpeakerReconcilerTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-recon-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func library() async throws -> (SpeakerLibrary, URL) {
        let dir = tempDir()
        let lib = try await SpeakerLibrary(
            databaseURL: dir.appendingPathComponent("speakers.sqlite"))
        return (lib, dir)
    }

    @Test("Unknown #N parsing")
    func unknownNumberParsing() {
        #expect(SpeakerReconciler.unknownNumber(in: "Unknown #3") == 3)
        #expect(SpeakerReconciler.unknownNumber(in: "Unknown #1") == 1)
        #expect(SpeakerReconciler.unknownNumber(in: "Steve") == nil)
        #expect(SpeakerReconciler.unknownNumber(in: "Unknown #") == nil)
    }

    /// Build a minimal `DiarizationResult` with one embedding per raw label.
    private func diarization(
        embeddings: [String: [Float]], revision: String = "rev-1"
    ) -> DiarizationResult {
        DiarizationResult(
            model: "pyannote/test", modelRevision: revision,
            audioDuration: .seconds(30),
            speakers: embeddings.keys.sorted(),
            spans: [],
            embeddings: embeddings
                .map { SpeakerEmbedding(speaker: $0.key, vector: $0.value) }
                .sorted { $0.speaker < $1.speaker })
    }

    private func axisVector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0.01, count: 256)
        v[axis % 256] = 1.0
        return v
    }

    @Test("reconcile: an empty library makes every cluster a new Unknown #N")
    func reconcileAllNew() async throws {
        let (lib, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reconciler = SpeakerReconciler(library: lib)
        let outcome = try await reconciler.reconcile(
            diarization: diarization(embeddings: [
                "SPEAKER_00": axisVector(0),
                "SPEAKER_01": axisVector(128),
            ]),
            recordingId: "rec_a", recordingFolderName: "a")

        #expect(outcome.newCount == 2)
        #expect(outcome.matchedCount == 0)
        // Deterministic placeholder numbering, sorted-label order.
        #expect(outcome.nameByRawLabel["SPEAKER_00"] == "Unknown #1")
        #expect(outcome.nameByRawLabel["SPEAKER_01"] == "Unknown #2")
        #expect(outcome.speakerIdByRawLabel["SPEAKER_00"]?.hasPrefix("spk_") == true)
    }

    @Test("reconcile: a returning cluster matches and reuses the library name")
    func reconcileMatchesReturning() async throws {
        let (lib, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First recording — one speaker, becomes Unknown #1.
        let reconciler = SpeakerReconciler(library: lib)
        _ = try await reconciler.reconcile(
            diarization: diarization(embeddings: ["SPEAKER_00": axisVector(7)]),
            recordingId: "rec_a", recordingFolderName: "a")
        let speakerID = try await lib.liveSpeakers().first!.id

        // Second recording — the same voice under a different raw label.
        let outcome = try await reconciler.reconcile(
            diarization: diarization(embeddings: ["SPEAKER_03": axisVector(7)]),
            recordingId: "rec_b", recordingFolderName: "b")
        #expect(outcome.matchedCount == 1)
        #expect(outcome.newCount == 0)
        #expect(outcome.nameByRawLabel["SPEAKER_03"] == "Unknown #1")
        #expect(outcome.speakerIdByRawLabel["SPEAKER_03"] == speakerID)
        // The match refined the centroid → two appearances.
        #expect(try await lib.speaker(id: speakerID)?.appearanceCount == 2)
    }

    @Test("reconcile: Unknown #N is never reused after a speaker ages out (SW2)")
    func unknownNumberNotReusedAfterAgeOut() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("speakers.sqlite")

        // First session, well in the past: create Unknown #1 + #2, then
        // delete both. After the recovery window they will be hard-aged-out
        // of `recoverableSpeakers` but still present as soft-deleted rows.
        let pastTime = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let lib = try await SpeakerLibrary(databaseURL: dbURL,
                                               clock: { pastTime })
            let recon = SpeakerReconciler(library: lib)
            _ = try await recon.reconcile(
                diarization: diarization(embeddings: [
                    "SPEAKER_00": axisVector(0),
                    "SPEAKER_01": axisVector(128),
                ]),
                recordingId: "rec_old", recordingFolderName: "old")
            for speaker in try await lib.liveSpeakers() {
                try await lib.delete(speakerId: speaker.id)
            }
        }

        // Re-open 31 days later — both deletes are past the recovery window,
        // so `recoverableSpeakers` is empty. A naive scan of only the
        // recoverable window would hand out "Unknown #1" again.
        let later = pastTime.addingTimeInterval(31 * 86_400)
        let lib = try await SpeakerLibrary(databaseURL: dbURL, clock: { later })
        #expect(try await lib.recoverableSpeakers().isEmpty)
        #expect(try await lib.allDeletedSpeakers().count == 2)

        let recon = SpeakerReconciler(library: lib)
        let outcome = try await recon.reconcile(
            diarization: diarization(embeddings: ["SPEAKER_00": axisVector(64)]),
            recordingId: "rec_new", recordingFolderName: "new")
        // The next number is #3 — #1 and #2 are not reused even though their
        // speakers have aged out of the recoverable window.
        #expect(outcome.nameByRawLabel["SPEAKER_00"] == "Unknown #3")
    }

    @Test("reconcile: a cross-revision cluster never matches — becomes new")
    func reconcileCrossRevisionIsNew() async throws {
        let (lib, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reconciler = SpeakerReconciler(library: lib)
        _ = try await reconciler.reconcile(
            diarization: diarization(
                embeddings: ["SPEAKER_00": axisVector(4)], revision: "rev-OLD"),
            recordingId: "rec_a", recordingFolderName: "a")

        // The same embedding under a new model revision is not comparable.
        let outcome = try await reconciler.reconcile(
            diarization: diarization(
                embeddings: ["SPEAKER_00": axisVector(4)], revision: "rev-NEW"),
            recordingId: "rec_b", recordingFolderName: "b")
        #expect(outcome.newCount == 1)
        #expect(outcome.matchedCount == 0)
        #expect(outcome.nameByRawLabel["SPEAKER_00"] == "Unknown #2")
    }
}
