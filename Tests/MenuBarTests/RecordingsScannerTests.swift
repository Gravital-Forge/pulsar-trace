import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// Epic 8 — `RecordingsScanner` builds the menubar recordings list (R31) from
/// the `metadata.json` sidecars under the output folder(s).
@Suite("RecordingsScanner (Epic 8)")
@MainActor
struct RecordingsScannerTests {

    /// A `MenuBarSettings` whose output folder is `root`, persisted to a
    /// throwaway suite so the bookmark resolves.
    private func settings(outputRoot: URL) throws -> MenuBarSettings {
        let suite = "pt-scanner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = MenuBarSettings(defaults: defaults)
        settings.outputFolderBookmark = try MenuBarSettings.makeBookmark(
            for: outputRoot)
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
        #expect(scanner.recordings.first?.speakers.contains("Steve") == true)
        #expect(scanner.recordings.first?.isRefined == true)
    }

    @Test("a folder without metadata.json is excluded")
    func folderWithoutMetadataExcluded() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "good", recordingId: "rec_good")
        // A bare folder with no metadata.json — not a recording.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-recording"),
            withIntermediateDirectories: true)

        let scanner = RecordingsScanner(settings: try settings(outputRoot: root))
        await scanner.refresh()

        #expect(scanner.recordings.map(\.id) == ["rec_good"])
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

    @Test("reRefine runs the injected refiner and rescans")
    func reRefineInvokesInjectedRefiner() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try MenuBarFixtures.makeRecordingFolder(
            root: root, name: "standup", recordingId: "rec_x")

        let refinedFolder = Mailbox()
        let scanner = RecordingsScanner(
            settings: try settings(outputRoot: root),
            reRefiner: { url in await refinedFolder.set(url) })
        await scanner.refresh()

        let entry = try #require(scanner.recordings.first)
        await scanner.reRefine(entry)

        #expect(await refinedFolder.value()?.lastPathComponent == "standup")
        #expect(scanner.lastError == nil)
    }

    /// A tiny `Sendable` mailbox for capturing a value from a `@Sendable`
    /// closure.
    private actor Mailbox {
        private var url: URL?
        func set(_ u: URL) { url = u }
        func value() -> URL? { url }
    }
}
