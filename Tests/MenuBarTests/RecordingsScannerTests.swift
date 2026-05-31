import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// `RecordingsScanner` builds the menubar recordings list (R31) from
/// the `metadata.json` sidecars under the output folder(s).
@Suite("RecordingsScanner")
@MainActor
struct RecordingsScannerTests {

    /// A `MenuBarSettings` whose output folder is `root`, persisted to a
    /// throwaway suite.
    private func settings(outputRoot: URL) throws -> MenuBarSettings {
        let suite = "pt-scanner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = MenuBarSettings(defaults: defaults)
        settings.outputFolderPath = outputRoot.path
        return settings
    }

    @Test("three recording folders decode into three entries, newest first")
    func threeRecordingsSortedDescending() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-01-standup", recordingId: "rec_a",
            recordingStart: "2026-05-01T09:00:00Z")
        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-03-review", recordingId: "rec_c",
            recordingStart: "2026-05-03T09:00:00Z")
        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-02-sync", recordingId: "rec_b",
            recordingStart: "2026-05-02T09:00:00Z")

        let scanner = RecordingsScanner(settings: try settings(outputRoot: root))
        await scanner.refresh()

        #expect(scanner.recordings.count == 3)
        #expect(scanner.recordings.map(\.id) == ["rec_c", "rec_b", "rec_a"])
        #expect(scanner.recordings.first?.speakers
            .contains(where: { $0.label == "Steve" }) == true)
        #expect(scanner.recordings.first?.isRefined == true)
    }

    @Test("an empty/garbage folder (no metadata, no live.md) is excluded")
    func emptyFolderExcluded() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "good", recordingId: "rec_good")
        // A bare folder with no metadata.json and no live.md — not a recording.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-recording"),
            withIntermediateDirectories: true)

        let scanner = RecordingsScanner(settings: try settings(outputRoot: root))
        await scanner.refresh()

        #expect(scanner.recordings.map(\.id) == ["rec_good"])
    }

    @Test("an unrefined folder (live.md, no metadata.json) surfaces as isRefined == false (FIX 3)")
    func unrefinedFolderSurfaces() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A refined recording and a just-recorded (unrefined) recording.
        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "2026-05-01-standup", recordingId: "rec_a",
            recordingStart: "2026-05-01T09:00:00Z")
        try MenuBarFixtures.makeUnrefinedRecordingFolder(
            root: root, name: "2026-05-02-143005")

        let scanner = RecordingsScanner(settings: try settings(outputRoot: root))
        await scanner.refresh()

        #expect(scanner.recordings.count == 2)
        let unrefined = try #require(
            scanner.recordings.first { !$0.isRefined })
        #expect(unrefined.displayName == "2026-05-02-143005")
        #expect(unrefined.speakers.isEmpty)
        // The refined recording still reports isRefined == true.
        #expect(scanner.recordings.contains { $0.isRefined })
    }

    @Test("an unrefined folder with only audio-system.wav also surfaces (FIX 3)")
    func unrefinedAudioOnlyFolderSurfaces() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent(
            "2026-05-03-090000", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        try Data([0x52, 0x49, 0x46, 0x46]).write(
            to: folder.appendingPathComponent(
                RecordingFolder.FileName.audioSystem))

        let scanner = RecordingsScanner(settings: try settings(outputRoot: root))
        await scanner.refresh()

        #expect(scanner.recordings.count == 1)
        #expect(scanner.recordings.first?.isRefined == false)
    }

    @Test("a folder with malformed metadata.json is skipped, not fatal")
    func malformedMetadataSkipped() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "good", recordingId: "rec_good")
        // A folder whose metadata.json is invalid JSON.
        let bad = root.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bad, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(
            to: bad.appendingPathComponent(RecordingFolder.FileName.metadata))

        let scanner = RecordingsScanner(settings: try settings(outputRoot: root))
        await scanner.refresh()

        // The good recording still surfaces; the malformed one is dropped.
        #expect(scanner.recordings.map(\.id) == ["rec_good"])
    }

}
