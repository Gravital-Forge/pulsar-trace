import Testing
import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("WriteToolsEdit")
struct WriteToolsEditTests {

    struct NoRecording: RecordingsProviding {
        func snapshot() async -> [RecordingEntry] { [] }
        func liveRecordingID() async -> String? { nil }
    }

    private func makeFolder(root: URL, name: String, recordingId: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let md = """
        <!-- pulsartrace:final -->
        ## Transcript

        **[00:00:03] Steve:** Hello there.

        """
        try Data(md.utf8).write(to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        let meta = try RefinementMetadata(
            recordingId: recordingId, recordingStart: "2026-05-01T09:00:00Z",
            refinedAt: "2026-05-01T10:00:00Z", durationSeconds: 30,
            speakers: [.init(label: "Steve", isMicrophone: false, speakerId: "spk_x")],
            whisperModel: .init(name: "base", sha256: "x"), diarizationModel: nil,
            language: "en", sourceBasename: "m.wav").encoded()
        try meta.write(to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))
        return folder
    }

    @Test("rename_speaker rewrites final.md and returns the rewritten recording ids")
    func renameTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeFolder(root: root, name: "standup", recordingId: "rec_standup")

        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await library.createSpeaker(
            name: "Steve", centroid: Array(repeating: 0.1, count: 256), modelRevision: "rev1",
            recordingId: "rec_standup", recordingFolderName: folder.lastPathComponent)
        let service = SpeakerEditService(library: library, events: nil)
        let gate = RecordingGate(recordings: NoRecording())

        let tool = WriteTools.renameSpeaker(service: service, gate: gate, outputRoots: { [root] })
        let result = await tool.handler(["speaker_id": .string(steve.id), "to": .string("Steven")])

        #expect(result.isError != true)
        let text: String = { if case let .text(t, _, _) = result.content.first { return t }; return "" }()
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect((json?["rewritten_recording_ids"] as? [String]) == ["rec_standup"])
        let finalText = try String(contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        #expect(finalText.contains("] Steven:**"))
    }

    @Test("rename_speaker with missing arguments errors")
    func renameMissingArgs() async throws {
        let library = try await SpeakerLibrary(databaseURL:
            FileManager.default.temporaryDirectory.appendingPathComponent("pt-\(UUID().uuidString).sqlite"))
        let tool = WriteTools.renameSpeaker(
            service: SpeakerEditService(library: library, events: nil),
            gate: RecordingGate(recordings: NoRecording()), outputRoots: { [] })
        #expect(await tool.handler(["speaker_id": .string("spk_x")]).isError == true)
    }
}
