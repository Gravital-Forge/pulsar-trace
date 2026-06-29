import Testing
import Foundation
@testable import PulsarTraceEngine

/// The shared speaker-edit orchestration (PT-P6-R9). These tests drive the
/// service directly — the path the MCP and CLI callers take when they bypass
/// the menubar view model — over hand-built fixture recording folders.
@Suite("SpeakerEditService")
struct SpeakerEditServiceTests {

    // MARK: - Fixtures (self-contained; mirrors FinalMarkdownRewriterTests)

    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ses-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    static let finalMarkdown = """
        <!-- pulsartrace:final -->
        ## Transcript — 2026-05-01 09:00

        **[00:00:03] Unknown #1:** Morning everyone, let us start.

        **[00:00:09] Steve:** Did Unknown #1 send the agenda yet?

        **[00:00:15] Unknown #1+Steve:** Yes — over to you.

        **[00:00:20] You:** Thanks, I will share my screen.

        """

    func metadata(recordingId: String) throws -> Data {
        try RefinementMetadata(
            recordingId: recordingId,
            recordingStart: "2026-05-01T09:00:00Z",
            refinedAt: "2026-05-01T10:00:00Z",
            durationSeconds: 30,
            speakers: [
                .init(label: "Unknown #1", isMicrophone: false, speakerId: "spk_aaa"),
                .init(label: "Steve", isMicrophone: false, speakerId: "spk_bbb"),
                .init(label: "You", isMicrophone: true, speakerId: nil),
            ],
            whisperModel: .init(name: "base", sha256: "deadbeef"),
            diarizationModel: nil,
            language: "en",
            sourceBasename: "meeting.wav").encoded()
    }

    @discardableResult
    func makeRecordingFolder(root: URL, name: String, recordingId: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.finalMarkdown.utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        try metadata(recordingId: recordingId).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))
        return folder
    }

    func eventTypes(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return obj["type"] as? String
            }
    }

    func centroid(_ v: Float) -> [Float] { Array(repeating: v, count: 256) }

    // MARK: - T1: name validation

    @Test("validateName rejects empty, whitespace, and + * ` names; accepts a normal name")
    func validateNameRule() throws {
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("  ") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("Ali+ce") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("a*b") }
        #expect(throws: SpeakerEditService.EditError.self) { try SpeakerEditService.validateName("a`b") }
        try SpeakerEditService.validateName("Alice")  // does not throw
    }
}
