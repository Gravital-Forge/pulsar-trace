// PT-P7-R4
import Foundation
import PulsarTraceEngine

/// Builds the isolated, pre-seeded home the UI suites launch against
/// (PT-P7-R4; pre-seeded speaker state per PT-P7-D6). Seeding goes through
/// the real `SpeakerLibrary` and the real file formats so the app reads
/// exactly what refinement would have written — no hand-rolled SQLite, no
/// schema drift.
struct SeededHome {
    let home: URL
    let suite: String
    let outputRoot: URL
    /// Stable ids of the seeded speakers, keyed by name.
    let speakerIds: [String: String]
    /// The two seeded recording folder basenames, oldest first.
    static let recordingFolders = ["2026-06-01-090000", "2026-06-02-100000"]

    /// The `PULSARTRACE_HOME` / `PULSARTRACE_DEFAULTS_SUITE` pair (PT-P7-R1).
    /// Callers merge fixtures or `PULSARTRACE_MODELS_DIR` on top.
    var launchEnvironment: [String: String] {
        ["PULSARTRACE_HOME": home.path,
         "PULSARTRACE_DEFAULTS_SUITE": suite]
    }

    /// Remove the home tree and the suite's persistent defaults domain.
    func tearDown() {
        try? FileManager.default.removeItem(at: home)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    static func make() async throws -> SeededHome {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-ui-seed-\(UUID().uuidString)")
        let outputRoot = home.appendingPathComponent(
            "Documents/PulsarTrace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputRoot, withIntermediateDirectories: true)

        // Settings: safe defaults per PT-P7-R9 — output folder inside the home,
        // system audio on, no hotkey, MCP off.
        let suite = "com.gravitalforge.PulsarTrace.uitest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(outputRoot.path, forKey: "outputFolderPath")     // PT-P7-R9
        defaults.set(true, forKey: "systemAudioEnabled")              // PT-P7-R9
        defaults.set(false, forKey: "mcpServerEnabled")               // PT-P7-R9
        // No `globalHotkey` key is written — an absent key loads as `nil`
        // (PT-P7-R9: the seeded suite carries no record-toggle hotkey).

        // Speaker library — the same paths the app resolves under this home.
        let paths = AppPaths(home: home)
        try FileManager.default.createDirectory(
            at: paths.applicationSupport, withIntermediateDirectories: true)
        let events = EventWriter(directory: paths.eventsDirectory)
        await events.bootstrap()
        let library = try await SpeakerLibrary(
            databaseURL: paths.speakersDatabaseURL, events: events)

        func centroid(_ v: Float) -> [Float] {
            Array(repeating: v, count: 256)
        }
        let rec1 = RecordingFolder.recordingId(forName: recordingFolders[0])
        let rec2 = RecordingFolder.recordingId(forName: recordingFolders[1])

        // Alice: two appearances (rec1 then rec2). Bob: one (rec1).
        // Carol: one (rec2). All on the same model revision so a returning
        // voice folds into its centroid rather than being refused.
        let alice = try await library.createSpeaker(
            name: "Alice", centroid: centroid(0.1), modelRevision: "seed-r1",
            recordingId: rec1, recordingFolderName: recordingFolders[0])
        _ = try await library.recordAppearance(
            speakerId: alice.id, centroid: centroid(0.1),
            modelRevision: "seed-r1", recordingId: rec2,
            recordingFolderName: recordingFolders[1])
        let bob = try await library.createSpeaker(
            name: "Bob", centroid: centroid(0.5), modelRevision: "seed-r1",
            recordingId: rec1, recordingFolderName: recordingFolders[0])
        let carol = try await library.createSpeaker(
            name: "Carol", centroid: centroid(0.9), modelRevision: "seed-r1",
            recordingId: rec2, recordingFolderName: recordingFolders[1])

        // Two refined recordings whose transcripts name the seeded speakers.
        try writeRecording(
            root: outputRoot, folder: recordingFolders[0], recordingId: rec1,
            startStamp: "2026-06-01T09:00:00Z",
            speakers: [("Alice", alice.id), ("Bob", bob.id)])
        try writeRecording(
            root: outputRoot, folder: recordingFolders[1], recordingId: rec2,
            startStamp: "2026-06-02T10:00:00Z",
            speakers: [("Alice", alice.id), ("Carol", carol.id)])

        return SeededHome(
            home: home, suite: suite, outputRoot: outputRoot,
            speakerIds: ["Alice": alice.id, "Bob": bob.id, "Carol": carol.id])
    }

    /// Write one refined recording folder — `final.md` (completion marker +
    /// per-utterance lines) and `metadata.json` — mirroring the real refine
    /// output formats and the sibling fixture in `SpeakerEditServiceTests`.
    /// A folder is listed in the Recordings pane iff it holds a decodable
    /// `metadata.json`; `final.md`'s presence makes the entry `isRefined`.
    private static func writeRecording(
        root: URL, folder: String, recordingId: String, startStamp: String,
        speakers: [(name: String, id: String)]
    ) throws {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        var lines = ["<!-- pulsartrace:final -->",
                     "## Transcript — \(folder)", ""]
        for (offset, speaker) in speakers.enumerated() {
            lines.append("**[00:0\(offset):05] \(speaker.name):** "
                + "Agreed, let us review the quarterly numbers now.")
            lines.append("")
        }
        lines.append("**[00:0\(speakers.count):05] You:** "
            + "Thanks everyone, sending the notes after this.")
        lines.append("")
        try lines.joined(separator: "\n").write(
            to: dir.appendingPathComponent(RecordingFolder.FileName.final),
            atomically: true, encoding: .utf8)

        // Named system-stream speakers carry their library ids; "You" is the
        // mic stream (never diarized, no library id).
        var metaSpeakers = speakers.map {
            RefinementMetadata.Speaker(
                label: $0.name, isMicrophone: false, speakerId: $0.id)
        }
        metaSpeakers.append(RefinementMetadata.Speaker(
            label: "You", isMicrophone: true, speakerId: nil))

        let metadata = try RefinementMetadata(
            recordingId: recordingId,
            recordingStart: startStamp,
            refinedAt: startStamp,
            durationSeconds: 180,
            speakers: metaSpeakers,
            whisperModel: .init(name: "seed", sha256: "seed"),
            diarizationModel: nil,
            language: "en",
            sourceBasename: "\(folder).wav").encoded()
        try metadata.write(
            to: dir.appendingPathComponent(RecordingFolder.FileName.metadata))
    }
}
