import Foundation
import Testing
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@MainActor
@Suite("TranscriptDetailModel")
struct TranscriptDetailModelTests {

    static func makeModel() -> (TranscriptDetailModel, RefinementJobQueueViewModel) {
        let queueVM = RefinementJobQueueViewModel(
            queue: RefinementJobQueue(
                store: RefinementJobStore(directory: MenuBarFixtures.tempDir()),
                runJob: { _ in }))
        let model = TranscriptDetailModel(
            queueVM: queueVM, liveWatcher: LiveTranscriptWatcher())
        return (model, queueVM)
    }

    static func row(
        _ entry: RecordingEntry, isLive: Bool = false,
        badge: RecordingRow.Badge = .none
    ) -> RecordingRow {
        RecordingRow(entry: entry, isLive: isLive, badge: badge)
    }

    /// A refined entry in `root`. `name`/`recordingId` are parameterized so a
    /// test needing two *distinct* recordings (different ids) can ask for them
    /// — same name + same id in different roots would collide on `entry.id`,
    /// since the id comes from `metadata.json`, not the path.
    static func refinedEntry(
        in root: URL,
        name: String = "2026-05-01-090000",
        recordingId: String = "rec_a"
    ) throws -> RecordingEntry {
        let folder = try MenuBarFixtures.makeRecordingFolder(
            root: root, name: name, recordingId: recordingId)
        return RecordingEntry.decode(folderURL: folder)!
    }

    static func completedJob(recordingId: String, folderURL: URL) -> RefinementJob {
        RefinementJob(
            id: "job_1", recordingId: recordingId, folderURL: folderURL,
            modelName: "base", modelSHA256: "deadbeef", trigger: .manual,
            enqueuedAt: .now,
            state: .completed(durationSeconds: 60, speakerCount: 2))
    }

    // MARK: Source selection + three-way load (§4.2)

    @Test("a refined row loads final.md lines")
    func loadsFinal() async throws {
        let (model, _) = Self.makeModel()
        let entry = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        guard case .lines(let lines) = model.content else {
            Issue.record("expected .lines, got \(model.content)"); return
        }
        #expect(lines.contains { $0.contains("Morning everyone") })
    }

    @Test("a missing file yields the placeholder; an unreadable file yields loadError + Retry")
    func threeWayResult() async throws {
        let (model, _) = Self.makeModel()
        let folder = MenuBarFixtures.tempDir()
        let entry = RecordingEntry(
            id: "rec_x", recordingStart: .now, folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false)
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        #expect(model.content == .placeholder)

        // Unreadable: a directory where live.md should be → read fails.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("live.md"),
            withIntermediateDirectories: true)
        model.reload()
        await model.awaitLoadForTesting()
        #expect(model.content == .unreadable)
        #expect(model.banner == .loadError)
    }

    @Test("a live row streams (no file load) and shows no banner")
    func liveRow() throws {
        let (model, _) = Self.makeModel()
        let entry = RecordingEntry(
            id: "rec_live", recordingStart: .now,
            folderURL: MenuBarFixtures.tempDir(),
            durationSeconds: 0, speakers: [], isRefined: false)
        model.show(Self.row(entry, isLive: true, badge: .recordingNow(startedAt: .now)))
        #expect(model.content == .live)
        #expect(model.banner == .none)
    }

    // MARK: Banner decision table (§4.2)

    @Test("queued and refining rows banner with Cancel; failed rows banner with Retry")
    func queueBanners() async throws {
        let (model, _) = Self.makeModel()
        let entry = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()

        model.queueOverride = .queued
        #expect(model.banner == .queued)

        model.queueOverride = .refining(fraction: 0.45, stageName: "Diarizing")
        #expect(model.banner == .refining(fraction: 0.45, stageName: "Diarizing"))

        model.queueOverride = .failed(errorClass: "transcribeFailed", retryable: true)
        guard case .failed(_, _, let retryable) = model.banner, retryable else {
            Issue.record("expected retryable .failed, got \(model.banner)"); return
        }
    }

    @Test("unrefined idle row banners with the Refine prompt; refined steady row shows none")
    func intrinsicBanners() async throws {
        let (model, _) = Self.makeModel()
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeUnrefinedRecordingFolder(
            root: root, name: "2026-05-02-090000")
        let unrefined = RecordingEntry.decode(folderURL: folder)!
        model.show(Self.row(unrefined))
        await model.awaitLoadForTesting()
        #expect(model.banner == .unrefined)

        let refined = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(refined))
        await model.awaitLoadForTesting()
        #expect(model.banner == .none)
    }

    // MARK: The pending-refined-content gate (§4.2)

    @Test("refine completion with content on screen flips the banner, never the content")
    func noAutoSwap() async throws {
        let (model, _) = Self.makeModel()
        let entry = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        let before = model.content

        model.noteJobsTerminated([Self.completedJob(
            recordingId: entry.id, folderURL: entry.folderURL)])
        #expect(model.content == before)          // unchanged under the user
        #expect(model.banner == .refineCompleted) // … the banner is the signal

        model.showRefinedTranscript()
        await model.awaitLoadForTesting()
        #expect(model.banner != .refineCompleted) // explicit action reloads
    }

    @Test("refine completion over a placeholder reloads immediately")
    func immediateReloadFromPlaceholder() async throws {
        let (model, _) = Self.makeModel()
        let folder = MenuBarFixtures.tempDir()
        let entry = RecordingEntry(
            id: "rec_a", recordingStart: .now, folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false)
        model.show(Self.row(entry))
        await model.awaitLoadForTesting()
        #expect(model.content == .placeholder)

        // The refine pass writes final.md, then completes:
        try Data(MenuBarFixtures.finalMarkdown().utf8).write(
            to: folder.appendingPathComponent(RecordingFolder.FileName.final))
        model.noteJobsTerminated([Self.completedJob(
            recordingId: "rec_a", folderURL: folder)])
        await model.awaitLoadForTesting()
        guard case .lines = model.content else {
            Issue.record("expected immediate reload, got \(model.content)"); return
        }
    }

    @Test("selection change away and back reloads naturally (pending flag does not leak)")
    func selectionChangeClearsPending() async throws {
        let (model, _) = Self.makeModel()
        let a = try Self.refinedEntry(in: MenuBarFixtures.tempDir())
        model.show(Self.row(a))
        await model.awaitLoadForTesting()
        model.noteJobsTerminated([Self.completedJob(
            recordingId: a.id, folderURL: a.folderURL)])
        #expect(model.banner == .refineCompleted)

        // A *distinct* recording — different folder name AND recordingId, so
        // `b.id != a.id` and `show(b)` is a real selection change, not a no-op.
        let b = try Self.refinedEntry(
            in: MenuBarFixtures.tempDir(),
            name: "2026-05-03-090000", recordingId: "rec_b")
        model.show(Self.row(b))
        await model.awaitLoadForTesting()
        #expect(model.banner == .none)
    }
}
