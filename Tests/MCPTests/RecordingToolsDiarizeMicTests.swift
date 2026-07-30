import Testing
import Foundation
import MCP
import PulsarTraceEngine
import PulsarTraceMenuBar
@testable import PulsarTraceMCP

/// PT-R143 / PT-R144 — the MCP mic-diarization surface: `request_refine`'s
/// optional `diarize_mic` argument writes the `options.json` stamp before
/// enqueueing, and the recording DTO reports `diarize_mic_stamp` (input) and
/// `mic_diarized` (last refine's output).
@Suite("RecordingTools diarize-mic (PT-R143, PT-R144)")
struct RecordingToolsDiarizeMicTests {

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

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decode(_ result: CallTool.Result) -> [String: Any] {
        guard case let .text(text, _, _) = result.content.first,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [:] }
        return json
    }

    private func entry(id: String, folder: URL, refined: Bool = true) -> RecordingEntry {
        RecordingEntry(
            id: id, recordingStart: Date(timeIntervalSince1970: 0), folderURL: folder,
            durationSeconds: refined ? 60 : 0, speakers: [], isRefined: refined,
            customTitle: nil, language: refined ? "en" : nil,
            diarizeMicStamp: RecordingOptions.read(from: folder).diarizeMic)
    }

    @Test("request_refine with diarize_mic=true writes the stamp before enqueueing")
    func requestRefineWritesStamp() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let spy = SpyRefiner()
        let tool = RecordingTools.requestRefine(
            recordings: Fake(entries: [entry(id: "rec_x", folder: folder)]), refine: spy)

        #expect(RecordingOptions.read(from: folder).diarizeMic == false)
        let result = await tool.handler(["id": .string("rec_x"), "diarize_mic": .bool(true)])
        #expect(result.isError != true)
        #expect(RecordingOptions.read(from: folder).diarizeMic == true)
        #expect(await spy.calls.map(\.1) == ["rec_x"])
    }

    @Test("request_refine with diarize_mic=false reverts the stamp before enqueueing")
    func requestRefineRevertsStamp() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var on = RecordingOptions.defaults
        on.diarizeMic = true
        try on.write(to: folder)
        let spy = SpyRefiner()
        let tool = RecordingTools.requestRefine(
            recordings: Fake(entries: [entry(id: "rec_x", folder: folder)]), refine: spy)

        let result = await tool.handler(["id": .string("rec_x"), "diarize_mic": .bool(false)])
        #expect(result.isError != true)
        #expect(RecordingOptions.read(from: folder).diarizeMic == false)
    }

    @Test("request_refine without diarize_mic leaves the existing stamp untouched")
    func requestRefineOmittedKeepsStamp() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var on = RecordingOptions.defaults
        on.diarizeMic = true
        try on.write(to: folder)
        let spy = SpyRefiner()
        let tool = RecordingTools.requestRefine(
            recordings: Fake(entries: [entry(id: "rec_x", folder: folder)]), refine: spy)

        _ = await tool.handler(["id": .string("rec_x")])
        #expect(RecordingOptions.read(from: folder).diarizeMic == true)
    }

    @Test("get_recording_meta reports diarize_mic_stamp and mic_diarized")
    func metaReportsBothFlags() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Input stamp on.
        var options = RecordingOptions.defaults
        options.diarizeMic = true
        try options.write(to: folder)
        // A refined metadata.json with mic_diarized = true.
        let metadata = RefinementMetadata(
            recordingId: "rec_x",
            recordingStart: "2026-05-01T09:00:00Z",
            refinedAt: "2026-05-01T10:00:00Z",
            durationSeconds: 60,
            speakers: [.init(label: "You", isMicrophone: true, speakerId: nil)],
            whisperModel: .init(name: "base", sha256: "deadbeef"),
            diarizationModel: nil,
            language: "en",
            sourceBasename: "rec_x.wav",
            micDiarized: true)
        try metadata.encoded().write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))

        let tool = ReadTools.getRecordingMeta(
            recordings: Fake(entries: [entry(id: "rec_x", folder: folder)]))
        let json = decode(await tool.handler(["id": .string("rec_x")]))
        let rec = json["recording"] as? [String: Any]
        #expect(rec?["diarize_mic_stamp"] as? Bool == true)
        #expect(rec?["mic_diarized"] as? Bool == true)
    }

    @Test("an unstamped, unrefined recording reports both flags false")
    func metaDefaultsFalse() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = ReadTools.getRecordingMeta(
            recordings: Fake(entries: [entry(id: "rec_y", folder: folder, refined: false)]))
        let json = decode(await tool.handler(["id": .string("rec_y")]))
        let rec = json["recording"] as? [String: Any]
        #expect(rec?["diarize_mic_stamp"] as? Bool == false)
        #expect(rec?["mic_diarized"] as? Bool == false)
    }
}
