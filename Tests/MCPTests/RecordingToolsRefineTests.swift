import Testing
import Foundation
import MCP
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("RecordingToolsRefine")
struct RecordingToolsRefineTests {

    struct Fake: RecordingsProviding {
        let entries: [RecordingEntry]
        func snapshot() async -> [RecordingEntry] { entries }
        func liveRecordingID() async -> String? { nil }
    }

    actor SpyRefiner: RefineRequesting {
        private(set) var calls: [(URL, String)] = []
        func requestRefine(folderURL: URL, recordingId: String) async throws {
            calls.append((folderURL, recordingId))
        }
    }

    @Test("request_refine enqueues via the seam and returns immediately")
    func enqueues() async throws {
        let folder = URL(fileURLWithPath: "/tmp/rec_x")
        let entry = RecordingEntry(
            id: "rec_x", recordingStart: Date(timeIntervalSince1970: 0), folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false, customTitle: nil, language: nil)
        let spy = SpyRefiner()
        let tool = RecordingTools.requestRefine(recordings: Fake(entries: [entry]), refine: spy)

        let result = await tool.handler(["id": .string("rec_x")])
        #expect(result.isError != true)
        #expect(await spy.calls.map(\.1) == ["rec_x"])

        #expect(await tool.handler(["id": .string("rec_none")]).isError == true)
    }
}
