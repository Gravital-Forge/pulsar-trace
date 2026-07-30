import Testing
import Foundation
@testable import PulsarTraceEngine

/// The shared speaker-edit orchestration (PT-P6-R9). These tests drive the
/// service directly — the path the MCP and CLI callers take when they bypass
/// the menubar view model — over hand-built fixture recording folders.
@Suite("SpeakerEditService")
struct SpeakerEditServiceTests {

    // MARK: - Fixtures (self-contained; mirrors FinalMarkdownRewriterTests)

    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ses-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    static let finalMarkdown = """
        <!-- pulsartrace:final -->
        ## Transcript — 2026-05-01 09:00

        **[00:00:03] Unknown #1:** Morning everyone, let us start.

        **[00:00:09] Steve:** Did Unknown #1 send the agenda yet?

        **[00:00:15] Unknown #1+Steve:** Yes — over to you.

        **[00:00:20] You:** Thanks, I will share my screen.

        """

    func metadata(recordingId: String) throws -> Data {
        try RefinementMetadata(
            recordingId: recordingId,
            recordingStart: "2026-05-01T09:00:00Z",
            refinedAt: "2026-05-01T10:00:00Z",
            durationSeconds: 30,
            speakers: [
                .init(label: "Unknown #1", isMicrophone: false, speakerId: "spk_aaa"),
                .init(label: "Steve", isMicrophone: false, speakerId: "spk_bbb"),
                .init(label: "You", isMicrophone: true, speakerId: nil),
            ],
            whisperModel: .init(name: "base", sha256: "deadbeef"),
            diarizationModel: nil,
            language: "en",
            sourceBasename: "meeting.wav").encoded()
    }

    @discardableResult
    func makeRecordingFolder(root: URL, name: String, recordingId: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.finalMarkdown.utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        try metadata(recordingId: recordingId).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))
        return folder
    }

    func eventTypes(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return obj["type"] as? String
            }
    }

    func centroid(_ v: Float) -> [Float] { Array(repeating: v, count: 256) }

    // MARK: - T1: name validation

    @Test("validateName rejects empty, whitespace, and + * ` names; accepts a normal name")
    func validateNameRule() throws {
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("  ") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("Ali+ce") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("a*b") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("a`b") }
        try SpeakerEditService.validateName("Alice")  // does not throw
    }

    // MARK: - T2: rename + merge

    @Test("rename rewrites past final.md and emits speaker_renamed before final_md_rewritten")
    func renameRewritesAndOrdersEvents() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")

        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)

        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(library: library, events: events)

        let result = try await service.rename(
            speakerId: steve.id, to: "Steven", outputFolderRoots: [root])

        #expect(result.rewrittenRecordingIds == ["rec_standup"])
        let finalText = try String(contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Steven:**"))
        #expect(!finalText.contains("] Steve:**"))
        #expect(try await library.liveSpeakers().first { $0.id == steve.id }?.name == "Steven")

        await events.flush()
        let log = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
        let renamedIdx = log.range(of: "speaker_renamed")
        let rewrittenIdx = log.range(of: "final_md_rewritten")
        #expect(renamedIdx != nil && rewrittenIdx != nil)
        #expect(renamedIdx!.lowerBound < rewrittenIdx!.lowerBound)
    }

    @Test("rename to the same name is a no-op — no rewrite, no event")
    func renameUnchangedIsNoOp() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: "standup")
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(library: library, events: events)

        let result = try await service.rename(speakerId: steve.id, to: "Steve", outputFolderRoots: [root])

        #expect(result.rewrittenRecordingIds.isEmpty)
        await events.flush()
        #expect(try eventTypes(in: await events.currentFileURL()).isEmpty)
    }

    @Test("merge rewrites the merged-away label to the primary and emits speaker_merged first")
    func mergeRewritesAndOrders() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let primary = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let other = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(library: library, events: events)

        let result = try await service.merge(
            primaryId: primary.id, otherId: other.id, outputFolderRoots: [root])

        #expect(result.rewrittenRecordingIds == ["rec_standup"])
        let finalText = try String(contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(!finalText.contains("] Steve:**"))
        await events.flush()
        let log = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
        #expect(log.range(of: "speaker_merged")!.lowerBound < log.range(of: "final_md_rewritten")!.lowerBound)
    }

    // MARK: - T3: split

    @Test("split mints a new speaker and rewrites the moved recording to the new name")
    func splitRewritesMovedRecording() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        // One speaker "Unknown #1" appearing in rec_standup; split it out under a new name.
        let original = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(library: library, events: events)

        let result = try await service.split(
            originalId: original.id, movingRecordingIds: ["rec_standup"],
            newName: "Alice", outputFolderRoots: [root])

        #expect(result.rewrittenRecordingIds == ["rec_standup"])
        let finalText = try String(contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Alice:**"))
        #expect(!finalText.contains("] Unknown #1:**"))
        await events.flush()
        let log = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
        #expect(log.range(of: "speaker_split")!.lowerBound < log.range(of: "final_md_rewritten")!.lowerBound)
    }

    @Test("split with an invalid new name throws before mutating")
    func splitRejectsInvalidName() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let original = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: "standup")
        let service = SpeakerEditService(library: library, events: nil)

        await #expect(throws: SpeakerEditService.EditError.self) {
            _ = try await service.split(
                originalId: original.id, movingRecordingIds: ["rec_standup"],
                newName: "  ", outputFolderRoots: [root])
        }
    }

    // MARK: - T4: delist + undelist

    @Test("delist drops the label and emits speaker_delisted before final_md_rewritten")
    func delistDropsLabel() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(library: library, events: events)

        let result = try await service.delist(speakerId: steve.id, outputFolderRoots: [root])

        #expect(result.rewrittenRecordingIds == ["rec_standup"])
        #expect(try await library.liveSpeakers().contains { $0.id == steve.id } == false)
        await events.flush()
        let log = try String(contentsOf: await events.currentFileURL(), encoding: .utf8)
        #expect(log.range(of: "speaker_delisted")!.lowerBound < log.range(of: "final_md_rewritten")!.lowerBound)
    }

    // PT-P8-R7 (closes KI-3): the mic speaker can no longer be a library
    // speaker named "You" — the name is reserved, so `createSpeaker(name: "You")`
    // throws before a delist could ever reach it. The old
    // `cannotDelistMicrophone` guard is dead code and removed; this test now
    // asserts the reservation that made it dead (the reservation-based
    // equivalent of the deleted mic-delist guard).
    @Test("the reserved You label cannot be created as a library speaker (PT-P8-R7)")
    func reservedYouCannotBeCreated() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))

        await #expect(throws: (any Error).self) {
            _ = try await library.createSpeaker(
                name: "You", centroid: centroid(0.5), modelRevision: "rev1",
                recordingId: "rec_x", recordingFolderName: "x")
        }
        #expect(try await library.liveSpeakers().isEmpty)
    }

    // MARK: - T1 (PT-P8): reserved owner label

    @Test("rename to You surfaces EditError.reservedName (PT-P8-R7, closes KI-3)")
    func renameToYouRejected() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let service = SpeakerEditService(library: library, events: nil)
        await #expect(throws: SpeakerEditService.EditError.reservedName("You")) {
            _ = try await service.rename(
                speakerId: steve.id, to: "You", outputFolderRoots: [root])
        }
    }

    @Test("undelist restores the label, emitting speaker_undelisted first")
    func undelistRestoresLabel() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let service = SpeakerEditService(library: library, events: events)
        _ = try await service.delist(speakerId: steve.id, outputFolderRoots: [root])

        let result = try await service.undelist(speakerId: steve.id, outputFolderRoots: [root])

        let finalText = try String(contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Steve:**"))
        #expect(result.rewrittenRecordingIds == ["rec_standup"])
        #expect(try await library.liveSpeakers().contains { $0.id == steve.id })
    }

    // MARK: - T5: unmerge / unsplit / delete / undelete

    @Test("unmerge emits exactly one speaker_unmerged (from the library), then the effects")
    func unmergeEmitsSingleCause() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        // The library emits `speaker_unmerged` itself, so it must share the
        // service's events writer (production wiring — see SpeakerEditorViewModel).
        let library = try await SpeakerLibrary(
            databaseURL: root.appendingPathComponent("speakers.sqlite"), events: events)
        let primary = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let other = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let service = SpeakerEditService(library: library, events: events)
        _ = try await service.merge(primaryId: primary.id, otherId: other.id, outputFolderRoots: [root])
        await events.flush()

        _ = try await service.unmerge(primaryId: primary.id, otherId: other.id, outputFolderRoots: [root])

        await events.flush()
        let types = try eventTypes(in: await events.currentFileURL())
        #expect(types.filter { $0 == "speaker_unmerged" }.count == 1)
        let unmergedIdx = types.firstIndex(of: "speaker_unmerged")!
        #expect(types[(unmergedIdx + 1)...].contains("final_md_rewritten"))
    }

    @Test("delete and undelete perform no rewrite and return empty results")
    func deleteUndeleteNoRewrite() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let service = SpeakerEditService(library: library, events: nil)

        let deleted = try await service.delete(speakerId: steve.id)
        #expect(deleted.rewrittenRecordingIds.isEmpty)
        #expect(try await library.liveSpeakers().contains { $0.id == steve.id } == false)

        let undeleted = try await service.undelete(speakerId: steve.id)
        #expect(undeleted.rewrittenRecordingIds.isEmpty)
        #expect(try await library.liveSpeakers().contains { $0.id == steve.id })
    }

    // MARK: - T6: concurrency (PT-P6-D1 single-writer)

    @Test("concurrent edits to the same recording both land (no lost final.md update)")
    func concurrentEditsSerialize() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeRecordingFolder(root: root, name: "standup", recordingId: "rec_standup")
        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        // Two speakers BOTH appearing in rec_standup (the fixture final.md labels
        // "Unknown #1" and "Steve"); rename both concurrently via two DIFFERENT services.
        let a = try await library.createSpeaker(
            name: "Unknown #1", centroid: centroid(0.1), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let b = try await library.createSpeaker(
            name: "Steve", centroid: centroid(0.2), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let events = EventWriter(directory: root.appendingPathComponent("events"))
        await events.bootstrap()
        let svc1 = SpeakerEditService(library: library, events: events)
        let svc2 = SpeakerEditService(library: library, events: events)

        async let r1 = svc1.rename(speakerId: a.id, to: "Alice", outputFolderRoots: [root])
        async let r2 = svc2.rename(speakerId: b.id, to: "Bob", outputFolderRoots: [root])
        _ = try await (r1, r2)

        // Both relabels must survive — neither edit lost the other's write.
        let finalText = try String(contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Alice:**"))
        #expect(finalText.contains("] Bob:**"))
        #expect(!finalText.contains("] Unknown #1:**"))
        #expect(!finalText.contains("] Steve:**"))
    }
}
