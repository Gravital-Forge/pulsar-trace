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
}
