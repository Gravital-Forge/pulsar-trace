import Testing
import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("RecordingToolsRename")
struct RecordingToolsRenameTests {

    struct Fake: RecordingsProviding {
        let entries: [RecordingEntry]
        func snapshot() async -> [RecordingEntry] { entries }
        func liveRecordingID() async -> String? { nil }
    }

    @Test("rename_recording writes the title.txt sidecar")
    func writesTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-rr-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("standup")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = RecordingEntry(
            id: "rec_standup", recordingStart: Date(timeIntervalSince1970: 0), folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false, customTitle: nil, language: nil)

        let tool = RecordingTools.renameRecording(recordings: Fake(entries: [entry]))
        let result = await tool.handler(["id": .string("rec_standup"), "title": .string("Weekly Standup")])
        #expect(result.isError != true)
        #expect(RecordingTitleStore.read(folderURL: folder) == "Weekly Standup")

        _ = await tool.handler(["id": .string("rec_standup"), "title": .string("  ")])
        #expect(RecordingTitleStore.read(folderURL: folder) == nil)

        #expect(await tool.handler(["id": .string("rec_nope"), "title": .string("X")]).isError == true)
    }
}
