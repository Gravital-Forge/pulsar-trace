import Testing
import Foundation
import MCP
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("RecordingGate")
struct RecordingGateTests {

    struct FakeRecordings: RecordingsProviding {
        let liveID: String?
        func snapshot() async -> [RecordingEntry] { [] }
        func liveRecordingID() async -> String? { liveID }
    }

    @Test("blocks when a recording is live, allows otherwise")
    func gating() async {
        let blocked = await RecordingGate(recordings: FakeRecordings(liveID: "rec_now")).blockIfRecording()
        #expect(blocked?.isError == true)

        let allowed = await RecordingGate(recordings: FakeRecordings(liveID: nil)).blockIfRecording()
        #expect(allowed == nil)
    }
}
