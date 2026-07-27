import Testing
import Foundation
import MCP
import PulsarTraceEngine
@testable import PulsarTraceMCP

@Suite("ReadToolsEvents")
struct ReadToolsEventsTests {

    @Test("recent_events returns events, filtered by type")
    func recentEvents() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pt-evt-\(UUID().uuidString)")
        let writer = EventWriter(directory: dir)
        await writer.bootstrap()
        try await writer.append(AppStartedEvent(version: "0.1.0", macosVersion: "26.3"))
        try await writer.append(SpeakerRenamedEvent(
            speakerId: "spk_1", oldName: "Unknown #1", newName: "Alice", appliedToRecordings: ["rec_x"]))
        await writer.flush()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tool = ReadTools.recentEvents(events: EventLogReader(directory: dir))
        let result = await tool.handler(["type": .string("speaker_renamed")])
        guard case let .text(text, _, _) = result.content.first else { Issue.record("no text"); return }
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let events = json?["events"] as? [[String: Any]] ?? []
        #expect(events.count == 1)
        #expect(events.first?["type"] as? String == "speaker_renamed")
    }
}
