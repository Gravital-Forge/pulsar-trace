import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RecordingOptions sidecar (PT-R136)")
struct RecordingOptionsTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-options-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("defaults: diarizeMic is off")
    func defaults() {
        #expect(RecordingOptions.defaults.diarizeMic == false)
    }

    @Test("write then read round-trips")
    func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = RecordingOptions.defaults
        options.diarizeMic = true
        try options.write(to: dir)
        #expect(RecordingOptions.read(from: dir).diarizeMic == true)
    }

    @Test("missing file reads as defaults")
    func missingFile() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(RecordingOptions.read(from: dir) == .defaults)
    }

    @Test("malformed file reads as defaults, never throws")
    func malformedFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{not json".utf8).write(
            to: dir.appendingPathComponent(RecordingFolder.FileName.options))
        #expect(RecordingOptions.read(from: dir) == .defaults)
    }

    @Test("the stamp is per-recording: another folder's stamp is untouched by later writes (PT-R146)")
    func stampsAreIndependent() throws {
        let a = tempDir()
        let b = tempDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        var on = RecordingOptions.defaults
        on.diarizeMic = true
        try on.write(to: a)
        try RecordingOptions.defaults.write(to: b)   // later recording, toggle now off
        #expect(RecordingOptions.read(from: a).diarizeMic == true)
        #expect(RecordingOptions.read(from: b).diarizeMic == false)
    }

    @Test("unknown keys are ignored")
    func unknownKeys() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"diarize_mic": true, "future_option": 7}"#.utf8).write(
            to: dir.appendingPathComponent(RecordingFolder.FileName.options))
        #expect(RecordingOptions.read(from: dir).diarizeMic == true)
    }
}
