import Foundation
import Testing
@testable import PulsarTraceEngine

/// PT-R140 — owner reassignment ("this is me" / "not me") through the shared
/// `SpeakerEditService`. Drives the service directly over hand-built,
/// byte-realistic recording folders: `final.md` + `metadata.json` (v3) written
/// with the same encoders production uses, plus a `mic-diarization.json` sidecar
/// carrying the cluster embeddings.
@Suite("SpeakerEditService owner designation (PT-R140)")
struct SpeakerEditServiceOwnerTests {

    // MARK: - Helpers

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-owner-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A unit vector along `axis` in the 256-d space.
    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256); v[axis] = 1; return v
    }

    private func writeFinal(_ body: String, to folder: URL) throws {
        try Data(body.utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
    }

    private func writeMetadata(
        recordingId: String, speakers: [RefinementMetadata.Speaker], to folder: URL
    ) throws {
        let metadata = RefinementMetadata(
            recordingId: recordingId,
            recordingStart: "2026-05-01T09:00:00Z",
            refinedAt: "2026-05-01T10:00:00Z",
            durationSeconds: 30,
            speakers: speakers,
            whisperModel: .init(name: "base", sha256: "deadbeef"),
            diarizationModel: .init(
                id: "FluidInference/speaker-diarization-coreml", revision: "rev-a"),
            language: "en",
            sourceBasename: "meeting.wav",
            micDiarized: true)
        try metadata.encoded().write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))
    }

    private func writeSidecar(
        speakers: [String: [Float]], to folder: URL, revision: String = "rev-a"
    ) throws {
        let result = DiarizationResult(
            model: "FluidInference/speaker-diarization-coreml",
            modelRevision: revision,
            audioDuration: .seconds(30),
            speakers: speakers.keys.sorted(),
            spans: speakers.keys.sorted().map {
                SpeakerSpan(speaker: $0, start: .seconds(0), end: .seconds(5))
            },
            embeddings: speakers
                .map { SpeakerEmbedding(speaker: $0.key, vector: $0.value) }
                .sorted { $0.speaker < $1.speaker })
        try MicDiarizationSidecar.write(result, to: folder)
    }

    /// A mic-diarized recording folder whose mic row is a MIS-attributed guest
    /// (`Unknown #1`, `is_microphone: true`, `speaker_id: guestId`). The sidecar
    /// carries the guest cluster embedding at `vec(5)`.
    @discardableResult
    private func makeMisattributedRecording(
        root: URL, guestId: String, name: String = "meet",
        recordingId: String = "rec_meet"
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try writeFinal("""
            <!-- pulsartrace:final -->
            ## Transcript — 2026-05-01 09:00

            **[00:00:03] Unknown #1:** hello from the room

            """, to: folder)
        try writeMetadata(
            recordingId: recordingId,
            speakers: [
                .init(label: "Unknown #1", isMicrophone: true, speakerId: guestId),
            ], to: folder)
        try writeSidecar(speakers: ["SPEAKER_00": vec(5)], to: folder)
        return folder
    }

    /// A mic-diarized recording folder whose mic row is the owner (`You`,
    /// `is_microphone: true`, `speaker_id: nil`). The sidecar carries the owner
    /// cluster at `vec(0)` plus a distinct guest at `vec(5)`.
    @discardableResult
    private func makeOwnerAttributedRecording(
        root: URL, name: String = "meet", recordingId: String = "rec_meet"
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try writeFinal("""
            <!-- pulsartrace:final -->
            ## Transcript — 2026-05-01 09:00

            **[00:00:03] You:** hi, this is me talking

            """, to: folder)
        try writeMetadata(
            recordingId: recordingId,
            speakers: [
                .init(label: "You", isMicrophone: true, speakerId: nil),
            ], to: folder)
        try writeSidecar(
            speakers: ["SPEAKER_00": vec(0), "SPEAKER_01": vec(5)], to: folder)
        return folder
    }

    // MARK: - designateOwner (T2)

    @Test("designateOwner relabels one recording, updates profile, deletes the solo speaker")
    func designateOwnerFullFlow() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let guest = try await library.createSpeaker(
            name: "Unknown #1", centroid: vec(5), modelRevision: "rev-a",
            recordingId: "rec_meet", recordingFolderName: "meet")
        let folder = try makeMisattributedRecording(root: root, guestId: guest.id)
        _ = folder

        let profile = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(
            library: library, events: events, ownerProfile: profile)

        let result = try await service.designateOwner(
            recordingId: "rec_meet", speakerId: guest.id, outputFolderRoots: [root])
        #expect(result.rewrittenRecordingIds == ["rec_meet"])

        let final = try String(
            contentsOf: root.appendingPathComponent("meet/final.md"), encoding: .utf8)
        #expect(final.contains("] You:**"))
        #expect(!final.contains("] Unknown #1:**"))

        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: root.appendingPathComponent("meet/metadata.json")))
        let you = metadata.speakers.first { $0.label == "You" }
        #expect(you?.speakerId == nil && you?.isMicrophone == true)

        // Solo speaker deleted; profile seeded from the sidecar embedding.
        #expect(try await library.liveSpeakers().isEmpty)
        #expect(await profile.snapshot()?.sampleCount == 1)

        // Causal order: owner_designated before final_md_rewritten.
        await events.flush()
        let log = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
        let cause = log.range(of: "owner_designated")
        let effect = log.range(of: "final_md_rewritten")
        #expect(cause != nil && effect != nil
                && cause!.lowerBound < effect!.lowerBound)
    }

    @Test("designateOwner on a multi-appearance guest removes only this appearance")
    func designateOwnerKeepsMultiAppearanceGuest() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let guest = try await library.createSpeaker(
            name: "Unknown #1", centroid: vec(5), modelRevision: "rev-a",
            recordingId: "rec_meet", recordingFolderName: "meet")
        // A second, unrelated appearance so the guest is NOT solo.
        _ = try await library.recordAppearance(
            speakerId: guest.id, centroid: vec(5), modelRevision: "rev-a",
            recordingId: "rec_other", recordingFolderName: "other")
        _ = try makeMisattributedRecording(root: root, guestId: guest.id)

        let profile = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))
        let service = SpeakerEditService(
            library: library, events: nil, ownerProfile: profile)

        _ = try await service.designateOwner(
            recordingId: "rec_meet", speakerId: guest.id, outputFolderRoots: [root])

        // Guest survives; only the reassigned appearance is gone.
        #expect(try await library.liveSpeakers().contains { $0.id == guest.id })
        let remaining = try await library.appearances(of: guest.id)
        #expect(remaining.map(\.recordingId) == ["rec_other"])
    }

    @Test("absent mic-diarization.json throws micDiarizationUnavailable")
    func sidecarRequired() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let guest = try await library.createSpeaker(
            name: "Unknown #1", centroid: vec(5), modelRevision: "rev-a",
            recordingId: "rec_meet", recordingFolderName: "meet")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meet"), withIntermediateDirectories: true)
        let service = SpeakerEditService(library: library, events: nil)
        await #expect(throws: SpeakerEditService.EditError
            .micDiarizationUnavailable) {
            _ = try await service.designateOwner(
                recordingId: "rec_meet", speakerId: guest.id,
                outputFolderRoots: [root])
        }
    }

    // MARK: - demoteOwner (T3)

    @Test("demoteOwner relabels You to a minted guest and subtracts the profile sample")
    func demoteOwnerFullFlow() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let profile = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")  // count 2
        let folder = try makeOwnerAttributedRecording(root: root)   // You lines + sidecar vec(0)
        _ = folder

        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(
            library: library, events: events, ownerProfile: profile)

        let result = try await service.demoteOwner(
            recordingId: "rec_meet", outputFolderRoots: [root])
        #expect(result.rewrittenRecordingIds == ["rec_meet"])

        let final = try String(
            contentsOf: root.appendingPathComponent("meet/final.md"), encoding: .utf8)
        #expect(!final.contains("] You:**"))
        #expect(final.contains("] Unknown #1:**"))

        let metadata = try JSONDecoder().decode(
            RefinementMetadata.self,
            from: Data(contentsOf: root.appendingPathComponent("meet/metadata.json")))
        let demoted = metadata.speakers.first { $0.label == "Unknown #1" }
        #expect(demoted?.isMicrophone == true)
        #expect(demoted?.speakerId?.hasPrefix("spk_") == true)

        #expect(await profile.snapshot()?.sampleCount == 1)   // one sample subtracted
        #expect(try await library.liveSpeakers().count == 1)  // guest minted

        await events.flush()
        let log = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
        #expect(log.range(of: "owner_demoted")!.lowerBound
                < log.range(of: "final_md_rewritten")!.lowerBound)
    }

    @Test("demoteOwner reconciles to an existing library speaker when one matches")
    func demoteOwnerReconcilesExisting() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        // A library speaker whose centroid IS the owner cluster (vec(0)) — the
        // demotion should reconcile to it rather than mint a new one.
        let existing = try await library.createSpeaker(
            name: "Dana", centroid: vec(0), modelRevision: "rev-a",
            recordingId: "rec_prev", recordingFolderName: "prev")
        let profile = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")
        _ = try makeOwnerAttributedRecording(root: root)

        let service = SpeakerEditService(
            library: library, events: nil, ownerProfile: profile)

        let result = try await service.demoteOwner(
            recordingId: "rec_meet", outputFolderRoots: [root])
        #expect(result.resolvedSpeakerId == existing.id)

        let final = try String(
            contentsOf: root.appendingPathComponent("meet/final.md"), encoding: .utf8)
        #expect(final.contains("] Dana:**"))
        // Reconciled — no new speaker minted; Dana now has the meet appearance.
        #expect(try await library.liveSpeakers().count == 1)
        let dana = try await library.appearances(of: existing.id)
        #expect(dana.contains { $0.recordingId == "rec_meet" })
    }

    @Test("a recording with no You mic row throws noOwnerAttribution")
    func demoteRequiresOwnerRow() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let folder = try makeMisattributedRecording(   // guest-only metadata (T2 builder)
            root: root, guestId: "spk_whoever")
        _ = folder
        let service = SpeakerEditService(library: library, events: nil)
        await #expect(throws: SpeakerEditService.EditError.noOwnerAttribution) {
            _ = try await service.demoteOwner(
                recordingId: "rec_meet", outputFolderRoots: [root])
        }
    }

    @Test("demoteOwner without a sidecar throws micDiarizationUnavailable")
    func demoteRequiresSidecar() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        // Owner-attributed metadata but NO mic-diarization.json.
        let folder = root.appendingPathComponent("meet", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try writeMetadata(
            recordingId: "rec_meet",
            speakers: [.init(label: "You", isMicrophone: true, speakerId: nil)],
            to: folder)
        let service = SpeakerEditService(library: library, events: nil)
        await #expect(throws: SpeakerEditService.EditError
            .micDiarizationUnavailable) {
            _ = try await service.demoteOwner(
                recordingId: "rec_meet", outputFolderRoots: [root])
        }
    }
}
