import Testing
import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("WriteToolsGate")
struct WriteToolsGateTests {

    struct Recording: RecordingsProviding {
        func snapshot() async -> [RecordingEntry] { [] }
        func liveRecordingID() async -> String? { "rec_live" }
    }

    @Test("every speaker write tool refuses during capture and leaves the library unchanged")
    func allRefuseDuringCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-wtg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        let steve = try await lib.createSpeaker(
            name: "Steve", centroid: Array(repeating: 0.2, count: 256), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let other = try await lib.createSpeaker(
            name: "Bob", centroid: Array(repeating: 0.3, count: 256), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")

        let tools = WriteTools.all(
            service: SpeakerEditService(library: lib, events: nil),
            gate: RecordingGate(recordings: Recording()), outputRoots: { [root] })
        #expect(tools.count == 9)

        let args: [String: [String: Value]] = [
            "rename_speaker": ["speaker_id": .string(steve.id), "to": .string("X")],
            "merge_speakers": ["primary_id": .string(steve.id), "other_id": .string(other.id)],
            "split_speaker": ["original_id": .string(steve.id), "moving_recording_ids": .array([.string("rec_x")]), "to": .string("X")],
            "unmerge_speakers": ["primary_id": .string(steve.id), "other_id": .string(other.id)],
            "unsplit_speaker": ["original_id": .string(steve.id), "new_id": .string(other.id)],
            "delete_speaker": ["speaker_id": .string(steve.id)],
            "undelete_speaker": ["speaker_id": .string(steve.id)],
            "delist_speaker": ["speaker_id": .string(steve.id)],
            "undelist_speaker": ["speaker_id": .string(steve.id)],
        ]
        for tool in tools {
            let result = await tool.handler(args[tool.name])
            #expect(result.isError == true, "\(tool.name) should refuse during capture")
        }

        let live = try await lib.liveSpeakers().map(\.id)
        #expect(live.contains(steve.id) && live.contains(other.id))
    }
}
