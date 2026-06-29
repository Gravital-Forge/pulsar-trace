import Testing
import Foundation
import MCP
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("ReadToolsRecordingMeta")
struct ReadToolsRecordingMetaTests {

    struct FakeRecordings: RecordingsProviding {
        let entries: [RecordingEntry]
        func snapshot() async -> [RecordingEntry] { entries }
        func liveRecordingID() async -> String? { nil }
    }

    private func entry(id: String) -> RecordingEntry {
        RecordingEntry(
            id: id, recordingStart: Date(timeIntervalSince1970: 0),
            folderURL: URL(fileURLWithPath: "/tmp/\(id)"), durationSeconds: 30,
            speakers: [], isRefined: true, customTitle: nil, language: "en")
    }

    @Test("get_recording_meta returns one recording by id, errors on a miss")
    func getById() async {
        let tool = ReadTools.getRecordingMeta(
            recordings: FakeRecordings(entries: [entry(id: "rec_x")]))

        let hit = await tool.handler(["id": .string("rec_x")])
        #expect(hit.isError != true)
        if case let .text(text, _, _) = hit.content.first {
            let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            #expect((json?["recording"] as? [String: Any])?["id"] as? String == "rec_x")
        } else { Issue.record("no text content") }

        let miss = await tool.handler(["id": .string("rec_nope")])
        #expect(miss.isError == true)

        let noArg = await tool.handler(nil)
        #expect(noArg.isError == true)
    }
}
