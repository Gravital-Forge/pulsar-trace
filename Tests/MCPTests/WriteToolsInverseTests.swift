import Testing
import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("WriteToolsInverse")
struct WriteToolsInverseTests {

    struct NoRecording: RecordingsProviding {
        func snapshot() async -> [RecordingEntry] { [] }
        func liveRecordingID() async -> String? { nil }
    }

    @Test("unmerge_speakers calls the service and returns rewritten ids")
    func unmergeTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-wti-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let primary = try await library.createSpeaker(
            name: "Unknown #1", centroid: Array(repeating: 0.1, count: 256), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let other = try await library.createSpeaker(
            name: "Steve", centroid: Array(repeating: 0.2, count: 256), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let service = SpeakerEditService(library: library, events: nil)
        _ = try await service.merge(primaryId: primary.id, otherId: other.id, outputFolderRoots: [root])

        let tool = WriteTools.unmergeSpeakers(
            service: service, gate: RecordingGate(recordings: NoRecording()), outputRoots: { [root] })
        let result = await tool.handler(["primary_id": .string(primary.id), "other_id": .string(other.id)])
        #expect(result.isError != true)

        let missing = await tool.handler(["primary_id": .string(primary.id)])
        #expect(missing.isError == true)
    }
}
