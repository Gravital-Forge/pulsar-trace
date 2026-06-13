import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// `RecordingEntry.decode(folderURL:)` reads a refined recording's
/// `metadata.json` sidecar and turns it into the richer
/// `[RecordingSpeaker]` shape the recordings-list UI renders as pills
/// (R31). This suite verifies the speaker fields — `label`, `speakerId`,
/// `isMicrophone` — flow through verbatim, and that the
/// `isUnknownPlaceholder` regex matches the precise
/// `Unknown #<digits>` shape `SpeakerReconciler.nextUnknownName()` emits.
@Suite("RecordingEntry decode")
@MainActor
struct RecordingEntryDecodeTests {

    /// `metadata.json`'s `label`, `speaker_id`, and `is_microphone` for each
    /// speaker must round-trip into `RecordingEntry.speakers`. The fixtures
    /// helper only sets `speakerId: nil`, so we hand-build a folder here.
    @Test("speaker label / speakerId / isMicrophone round-trip from metadata.json")
    func speakerFieldsRoundTrip() throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("2026-05-01-standup", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)

        // A final.md so isRefined is true (decode does NOT require it for the
        // metadata path, but other fields are clearer with it present).
        try Data("<!-- pulsartrace:final -->\n".utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))

        let metadata = RefinementMetadata(
            recordingId: "rec_test",
            recordingStart: "2026-05-01T09:00:00Z",
            refinedAt: "2026-05-01T10:00:00Z",
            durationSeconds: 75,
            speakers: [
                .init(label: "Unknown #1", isMicrophone: false, speakerId: nil),
                .init(label: "Steve", isMicrophone: false, speakerId: "spk_01HXYZ"),
                .init(label: "You", isMicrophone: true, speakerId: nil),
            ],
            whisperModel: .init(name: "base", sha256: "deadbeef"),
            diarizationModel: nil,
            language: "en",
            sourceBasename: "standup.wav")
        try metadata.encoded().write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.metadata))

        let entry = try #require(RecordingEntry.decode(folderURL: folder))
        #expect(entry.speakers.count == 3)

        let unknown = try #require(entry.speakers.first { $0.label == "Unknown #1" })
        #expect(unknown.speakerId == nil)
        #expect(unknown.isMicrophone == false)
        #expect(unknown.isUnknownPlaceholder)

        let steve = try #require(entry.speakers.first { $0.label == "Steve" })
        #expect(steve.speakerId == "spk_01HXYZ")
        #expect(steve.isMicrophone == false)
        #expect(steve.isUnknownPlaceholder == false)

        let you = try #require(entry.speakers.first { $0.label == "You" })
        #expect(you.speakerId == nil)
        #expect(you.isMicrophone)
        #expect(you.isUnknownPlaceholder == false)
    }

    /// `isUnknownPlaceholder` must match exactly the `Unknown #<digits>`
    /// shape `SpeakerReconciler.nextUnknownName()` emits — no spaces, no
    /// trailing letters, at least one digit.
    @Test(
        "isUnknownPlaceholder matches Unknown #<digits> only",
        arguments: [
            ("Unknown #1", true),
            ("Unknown #42", true),
            ("Unknown #999", true),
            ("Unknown", false),
            ("Unknown #", false),
            ("Unknown # 1", false),
            ("Unknown #1a", false),
            ("Unknown #1 ", false),
            ("unknown #1", false),
            ("Steve", false),
            ("You", false),
            // Unicode digit lookalikes must NOT match — only the ASCII 0-9
            // placeholders SpeakerReconciler emits drive the orange tint.
            ("Unknown #\u{FF11}", false),  // fullwidth digit 1
            ("Unknown #\u{0662}", false),  // Arabic-Indic digit 2
        ]
    )
    func unknownPlaceholderRegex(label: String, expected: Bool) {
        let speaker = RecordingSpeaker(
            label: label, speakerId: nil, isMicrophone: false)
        #expect(speaker.isUnknownPlaceholder == expected,
                "\(label) should be \(expected)")
    }

    /// `RecordingSpeaker.id` prefers `speakerId` and synthesizes a stable
    /// fallback from label + mic flag — so two `Unknown #1`-style speakers
    /// without an id (e.g. diarization skipped, library missing) still get
    /// distinct identities provided they differ on `isMicrophone`. This is
    /// load-bearing for `ForEach` rendering of the pill row.
    @Test("RecordingSpeaker.id prefers speakerId, falls back to label+mic")
    func recordingSpeakerIdentity() {
        let withId = RecordingSpeaker(
            label: "Steve", speakerId: "spk_abc", isMicrophone: false)
        #expect(withId.id == "spk_abc")

        let noId = RecordingSpeaker(
            label: "Steve", speakerId: nil, isMicrophone: false)
        #expect(noId.id == "label:Steve:false")

        let mic = RecordingSpeaker(
            label: "You", speakerId: nil, isMicrophone: true)
        #expect(mic.id == "label:You:true")
    }

    @Test("title.txt sidecar decodes into customTitle and displayTitle prefers it")
    func customTitleDecodes() throws {
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-01-090000", recordingId: "rec_a")
        try RecordingTitleStore.write("Quarterly sync", folderURL: folder)
        let entry = try #require(RecordingEntry.decode(folderURL: folder))
        #expect(entry.customTitle == "Quarterly sync")
        #expect(entry.displayTitle == "Quarterly sync")
        #expect(entry.defaultTitle != "Quarterly sync")
    }

    @Test("no sidecar → customTitle nil, displayTitle falls back to the date default")
    func noSidecar() throws {
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-01-090000", recordingId: "rec_a")
        let entry = try #require(RecordingEntry.decode(folderURL: folder))
        #expect(entry.customTitle == nil)
        #expect(entry.displayTitle == entry.defaultTitle)
    }

    @Test("title.txt sidecar decodes into customTitle for an unrefined folder too")
    func customTitleDecodesUnrefined() throws {
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeUnrefinedRecordingFolder(
            root: root, name: "2026-05-01-090000")
        try RecordingTitleStore.write("Draft notes", folderURL: folder)
        let entry = try #require(RecordingEntry.decode(folderURL: folder))
        #expect(entry.isRefined == false)
        #expect(entry.customTitle == "Draft notes")
        #expect(entry.displayTitle == "Draft notes")
    }

    /// `formatDuration` is what the recordings-list row shows under the pill
    /// strip — covers the hour boundary (where the format switches from
    /// `M:SS` to `H:MM:SS`), the defensive NaN/negative branches, and the
    /// truncate-fractional-seconds behaviour.
    @Test(
        "formatDuration",
        arguments: [
            (0.0, "0:00"),
            (1.0, "0:01"),
            (59.0, "0:59"),
            (60.0, "1:00"),
            (599.0, "9:59"),
            (3599.0, "59:59"),
            (3600.0, "1:00:00"),
            (3661.0, "1:01:01"),
            (37200.0, "10:20:00"),
            (75.9, "1:15"),
            (-1.0, "0:00"),
            (.nan, "0:00"),
            (.infinity, "0:00"),
        ]
    )
    func formatDuration(input: Double, expected: String) {
        #expect(RecordingEntry.formatDuration(input) == expected,
                "\(input) → \(expected)")
    }
}
