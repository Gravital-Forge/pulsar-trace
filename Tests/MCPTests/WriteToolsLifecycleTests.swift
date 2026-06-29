import Testing
import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

@Suite("WriteToolsLifecycle")
struct WriteToolsLifecycleTests {

    struct NoRecording: RecordingsProviding {
        func snapshot() async -> [RecordingEntry] { [] }
        func liveRecordingID() async -> String? { nil }
    }

    private func library(_ root: URL) async throws -> SpeakerLibrary {
        try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
    }

    @Test("delete then undelete via tools toggles library membership")
    func deleteUndelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-wtl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try await library(root)
        let steve = try await lib.createSpeaker(
            name: "Steve", centroid: Array(repeating: 0.2, count: 256), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let service = SpeakerEditService(library: lib, events: nil)
        let gate = RecordingGate(recordings: NoRecording())

        #expect(await WriteTools.deleteSpeaker(service: service, gate: gate)
            .handler(["speaker_id": .string(steve.id)]).isError != true)
        #expect(try await lib.liveSpeakers().contains { $0.id == steve.id } == false)

        #expect(await WriteTools.undeleteSpeaker(service: service, gate: gate)
            .handler(["speaker_id": .string(steve.id)]).isError != true)
        #expect(try await lib.liveSpeakers().contains { $0.id == steve.id })
    }

    @Test("delist_speaker refuses the microphone speaker")
    func delistMicRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-wtl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try await library(root)
        let you = try await lib.createSpeaker(
            name: "You", centroid: Array(repeating: 0.5, count: 256), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")
        let tool = WriteTools.delistSpeaker(
            service: SpeakerEditService(library: lib, events: nil),
            gate: RecordingGate(recordings: NoRecording()), outputRoots: { [root] })

        #expect(await tool.handler(["speaker_id": .string(you.id)]).isError == true)
    }
}
