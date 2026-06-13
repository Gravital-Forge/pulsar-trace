import Foundation
import PulsarTraceEngine

/// Shared test fixtures for the MenuBar suite — synthetic recording folders
/// (a `final.md` + `metadata.json`) and `SpeakerLibrary` helpers.
enum MenuBarFixtures {

    /// Create a unique throwaway temp directory.
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-menubar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A `final.md` body with a marker, header, and utterance lines — including
    /// a co-attributed `A+B` line and a prose mention that must NOT be rewritten.
    static func finalMarkdown(
        speakerA: String = "Unknown #1",
        speakerB: String = "Steve"
    ) -> String {
        """
        <!-- pulsartrace:final -->
        ## Transcript — 2026-05-01 09:00

        **[00:00:03] \(speakerA):** Morning everyone, mentioning \(speakerA) here.

        **[00:00:09] \(speakerB):** Did you send the agenda yet?

        **[00:00:15] \(speakerA)+\(speakerB):** Yes — over to you.

        **[00:00:20] You:** Thanks, I will share my screen.

        """
    }

    /// A `final.md` body whose only speaker label is `speaker` — for a
    /// recording that genuinely never involved a second speaker.
    static func soloFinalMarkdown(speaker: String) -> String {
        """
        <!-- pulsartrace:final -->
        ## Transcript — 2026-05-01 09:00

        **[00:00:03] \(speaker):** Just me here, talking to myself.

        **[00:00:09] \(speaker):** Still just me.

        """
    }

    /// Build a recording folder with `final.md` + `metadata.json`.
    @discardableResult
    static func makeRecordingFolder(
        root: URL,
        name: String,
        recordingId: String,
        recordingStart: String = "2026-05-01T09:00:00Z",
        durationSeconds: Double = 30,
        speakerLabels: [String] = ["Unknown #1", "Steve", "You"],
        withFinalMarkdown: Bool = true,
        finalMarkdownBody: String? = nil
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)

        if withFinalMarkdown {
            try Data((finalMarkdownBody ?? finalMarkdown()).utf8).write(
                to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        }

        let metadata = RefinementMetadata(
            recordingId: recordingId,
            recordingStart: recordingStart,
            refinedAt: "2026-05-01T10:00:00Z",
            durationSeconds: durationSeconds,
            speakers: speakerLabels.map {
                .init(label: $0, isMicrophone: $0 == "You", speakerId: nil)
            },
            whisperModel: .init(name: "base", sha256: "deadbeef"),
            diarizationModel: nil,
            language: "en",
            sourceBasename: "\(name).wav")
        try metadata.encoded().write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))
        return folder
    }

    /// Build an *unrefined* recording folder — a `live.md` (and optionally an
    /// `audio-system.wav`) but **no** `metadata.json`, as a just-recorded or
    /// failed-to-refine folder looks on disk (FIX 3).
    @discardableResult
    static func makeUnrefinedRecordingFolder(
        root: URL,
        name: String,
        withAudio: Bool = false
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try Data("<!-- pulsartrace:live -->\n## Transcript\n".utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.live))
        if withAudio {
            try Data([0x52, 0x49, 0x46, 0x46]).write(
                to: folder.appendingPathComponent(
                    RecordingFolder.FileName.audioSystem))
        }
        return folder
    }
}
