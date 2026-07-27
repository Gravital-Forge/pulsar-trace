import Testing
import Foundation
import MCP
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("ReadToolsRecordings")
struct ReadToolsRecordingsTests {

    struct FakeRecordings: RecordingsProviding {
        let entries: [RecordingEntry]
        let liveID: String?
        func snapshot() async -> [RecordingEntry] { entries }
        func liveRecordingID() async -> String? { liveID }
    }

    private func entry(id: String, start: String, refined: Bool) -> RecordingEntry {
        RecordingEntry(
            id: id,
            recordingStart: ISO8601DateFormatter().date(from: start) ?? .distantPast,
            folderURL: URL(fileURLWithPath: "/tmp/\(id)"),
            durationSeconds: refined ? 60 : 0,
            speakers: refined ? [RecordingSpeaker(label: "Steve", speakerId: "spk_1", isMicrophone: false)] : [],
            isRefined: refined,
            customTitle: nil,
            language: refined ? "en" : nil)
    }

    private func call(_ tool: MCPTool, _ args: [String: Value]?) async -> [String: Any] {
        let result = await tool.handler(args)
        guard case let .text(text, _, _) = result.content.first,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [:] }
        return json
    }

    @Test("list_recordings returns metadata, paths, is_live, and never content")
    func listsRecordings() async {
        let provider = FakeRecordings(
            entries: [entry(id: "rec_b", start: "2026-06-20T10:00:00Z", refined: true),
                      entry(id: "rec_a", start: "2026-06-19T10:00:00Z", refined: false)],
            liveID: "rec_a")
        let tool = ReadTools.listRecordings(recordings: provider)

        let json = await call(tool, nil)
        let recs = json["recordings"] as? [[String: Any]] ?? []
        #expect(recs.count == 2)
        let live = recs.first { $0["id"] as? String == "rec_a" }
        #expect(live?["is_live"] as? Bool == true)
        #expect(live?["refinement_state"] as? String == "live")
        let refined = recs.first { $0["id"] as? String == "rec_b" }
        #expect(refined?["language"] as? String == "en")
        #expect((refined?["final_path"] as? String)?.hasSuffix("final.md") == true)
        #expect(refined?["transcript"] == nil)
    }

    @Test("status and limit filter the result")
    func filters() async {
        let provider = FakeRecordings(
            entries: [entry(id: "rec_b", start: "2026-06-20T10:00:00Z", refined: true),
                      entry(id: "rec_a", start: "2026-06-19T10:00:00Z", refined: false)],
            liveID: nil)
        let tool = ReadTools.listRecordings(recordings: provider)

        let refinedOnly = await call(tool, ["status": .string("refined")])
        #expect((refinedOnly["recordings"] as? [[String: Any]])?.count == 1)

        let capped = await call(tool, ["limit": .int(1)])
        #expect((capped["recordings"] as? [[String: Any]])?.count == 1)

        let since = await call(tool, ["since": .string("2026-06-20T00:00:00Z")])
        #expect((since["recordings"] as? [[String: Any]])?.count == 1)
    }
}
