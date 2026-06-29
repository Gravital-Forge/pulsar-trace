import Testing
import Foundation
import MCP
import PulsarTraceEngine
@testable import PulsarTraceMCP

@Suite("ReadToolsSpeakers")
struct ReadToolsSpeakersTests {

    private func tempLibrary() async throws -> (SpeakerLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pt-spk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lib = try await SpeakerLibrary(databaseURL: root.appendingPathComponent("speakers.sqlite"))
        return (lib, root)
    }

    private func json(_ result: CallTool.Result) -> [String: Any] {
        guard case let .text(text, _, _) = result.content.first,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [:] }
        return obj
    }

    @Test("list_speakers returns live speakers; get_speaker adds appearances")
    func listAndGet() async throws {
        let (lib, root) = try await tempLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let steve = try await lib.createSpeaker(
            name: "Steve", centroid: Array(repeating: 0.1, count: 256), modelRevision: "rev1",
            recordingId: "rec_x", recordingFolderName: "x")

        let list = json(await ReadTools.listSpeakers(library: lib).handler(nil))
        let speakers = list["speakers"] as? [[String: Any]] ?? []
        #expect(speakers.contains { $0["id"] as? String == steve.id && $0["name"] as? String == "Steve" })

        let got = json(await ReadTools.getSpeaker(library: lib).handler(["id": .string(steve.id)]))
        let speaker = got["speaker"] as? [String: Any]
        #expect(speaker?["id"] as? String == steve.id)
        let appearances = speaker?["appearances"] as? [[String: Any]] ?? []
        #expect(appearances.contains { $0["recording_id"] as? String == "rec_x" })

        let miss = await ReadTools.getSpeaker(library: lib).handler(["id": .string("spk_nope")])
        #expect(miss.isError == true)
    }
}
