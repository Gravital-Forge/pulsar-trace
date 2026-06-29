import Testing
import Foundation
@testable import PulsarTraceEngine

@Suite("EventLogReader")
struct EventLogReaderTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pt-elr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("recent filters by type and since, newest first, across files")
    func filtersAndOrders() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {"ts":"2026-06-19T09:00:00Z","type":"app_started","id":"evt_1","version":1}
        {"ts":"2026-06-19T09:05:00Z","type":"speaker_renamed","id":"evt_2","version":1}
        """.write(to: dir.appendingPathComponent("2026-06-19.jsonl"), atomically: true, encoding: .utf8)
        try """
        {"ts":"2026-06-20T08:00:00Z","type":"speaker_renamed","id":"evt_3","version":1}
        """.write(to: dir.appendingPathComponent("2026-06-20.jsonl"), atomically: true, encoding: .utf8)

        let reader = EventLogReader(directory: dir)

        let renamed = try reader.recent(types: ["speaker_renamed"], limit: 100)
        #expect(renamed.map(\.type) == ["speaker_renamed", "speaker_renamed"])
        #expect(renamed.first?.ts == "2026-06-20T08:00:00Z")   // newest first

        let since = try reader.recent(since: "2026-06-20T00:00:00Z", limit: 100)
        #expect(since.map(\.ts) == ["2026-06-20T08:00:00Z"])

        let capped = try reader.recent(limit: 1)
        #expect(capped.count == 1)
    }
}
