import Foundation
import Testing
@testable import PulsarTraceMenuBar
@testable import PulsarTraceEngine

/// PT-R140 — the speaker editor's owner-reassignment actions ("This is me" /
/// "Not me") and the sidecar-gated visibility, exercised at the view-model
/// level. These are headless unit tests (no SwiftUI, no running app): they
/// drive `SpeakerEditorViewModel` over byte-realistic recording folders built
/// with the production writers.
@Suite("Speaker editor owner actions (PT-R140)")
@MainActor
struct SpeakerEditorViewModelOwnerTests {

    // MARK: - Fixtures

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256); v[axis] = 1; return v
    }

    private func settings(outputRoot: URL) throws -> MenuBarSettings {
        let defaults = UserDefaults(suiteName: "pt-sevm-owner-\(UUID().uuidString)")!
        let settings = MenuBarSettings(defaults: defaults)
        settings.outputFolderPath = outputRoot.path
        return settings
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

    private func writeSidecar(_ speakers: [String: [Float]], to folder: URL) throws {
        let result = DiarizationResult(
            model: "FluidInference/speaker-diarization-coreml",
            modelRevision: "rev-a",
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

    /// A mic-diarized recording folder with a MIS-attributed mic guest
    /// (`Unknown #1`, `is_microphone: true`, `speaker_id: guestId`) + sidecar.
    @discardableResult
    private func makeMisattributedRecording(
        root: URL, guestId: String, name: String = "meet"
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try Data("""
            <!-- pulsartrace:final -->
            ## Transcript — 2026-05-01 09:00

            **[00:00:03] Unknown #1:** hello from the room

            """.utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        try writeMetadata(
            recordingId: "rec_meet",
            speakers: [.init(label: "Unknown #1", isMicrophone: true, speakerId: guestId)],
            to: folder)
        try writeSidecar(["SPEAKER_00": vec(5)], to: folder)
        return folder
    }

    // MARK: - Tests

    @Test("designate action routes to the service and reloads")
    func designateRoutes() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let guest = try await library.createSpeaker(
            name: "Unknown #1", centroid: vec(5), modelRevision: "rev-a",
            recordingId: "rec_meet", recordingFolderName: "meet")
        let folder = try makeMisattributedRecording(root: root, guestId: guest.id)

        let profile = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))
        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root),
            ownerProfile: profile)
        await vm.reload()

        await vm.designateOwner(recordingId: "rec_meet", speakerId: guest.id)

        #expect(vm.lastError == nil)
        let final = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(final.contains("] You:**"))
        #expect(!final.contains("] Unknown #1:**"))

        // An undo toast is present whose action demotes the owner back.
        let toast = try #require(vm.undoToast)
        #expect(toast.message == "Attributed to you")

        // The solo guest was deleted; profile seeded from the sidecar.
        #expect(!vm.liveSpeakers.contains { $0.id == guest.id })
        #expect(await profile.snapshot()?.sampleCount == 1)

        // The undo (demote) round-trips the transcript back to a library name.
        await toast.action()
        #expect(vm.lastError == nil)
        let afterUndo = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(!afterUndo.contains("] You:**"))
    }

    @Test("owner actions are unavailable without mic-diarization.json")
    func gatedOnSidecar() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root))
        await vm.reload()

        // A recording folder WITHOUT the sidecar.
        let noSidecar = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(
            at: noSidecar, withIntermediateDirectories: true)
        #expect(vm.canReassignOwner(folderURL: noSidecar) == false)

        // A folder WITH the sidecar reads true.
        let guest = try await library.createSpeaker(
            name: "Unknown #1", centroid: vec(5), modelRevision: "rev-a",
            recordingId: "rec_meet", recordingFolderName: "meet")
        let withSidecar = try makeMisattributedRecording(root: root, guestId: guest.id)
        #expect(vm.canReassignOwner(folderURL: withSidecar) == true)
    }

    @Test("demote action routes to the service and offers a re-designate undo")
    func demoteRoutes() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let profile = OwnerVoiceProfileStore(
            fileURL: root.appendingPathComponent("owner-profile.json"))
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")
        _ = try await profile.update(embedding: vec(0), modelRevision: "rev-a")

        // An owner-attributed mic-diarized recording (You lines + sidecar vec(0)).
        let folder = root.appendingPathComponent("meet", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try Data("""
            <!-- pulsartrace:final -->
            ## Transcript — 2026-05-01 09:00

            **[00:00:03] You:** hi, this is me talking

            """.utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        try writeMetadata(
            recordingId: "rec_meet",
            speakers: [.init(label: "You", isMicrophone: true, speakerId: nil)],
            to: folder)
        try writeSidecar(["SPEAKER_00": vec(0), "SPEAKER_01": vec(5)], to: folder)

        let vm = SpeakerEditorViewModel(
            library: library, settings: try settings(outputRoot: root),
            ownerProfile: profile)
        await vm.reload()

        await vm.demoteOwner(recordingId: "rec_meet")

        #expect(vm.lastError == nil)
        let final = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(!final.contains("] You:**"))
        #expect(final.contains("] Unknown #1:**"))
        #expect(vm.liveSpeakers.count == 1)   // guest minted
        #expect(await profile.snapshot()?.sampleCount == 1)  // one sample subtracted

        let toast = try #require(vm.undoToast)
        #expect(toast.message == "No longer attributed to you")
    }
}
