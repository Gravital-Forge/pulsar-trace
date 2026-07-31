import Foundation
import Testing
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@MainActor
@Suite("RecordingsPaneModel")
struct RecordingsPaneModelTests {

    /// Fixed reference clock: 2026-06-10 15:00 local.
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 10; c.hour = 15
        return Calendar.current.date(from: c)!
    }()

    static func date(daysAgo: Int, hour: Int = 9) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return Calendar.current.date(
            bySettingHour: hour, minute: 30, second: 0, of: day)!
    }

    static func entry(
        id: String, start: Date, refined: Bool = true,
        speakers: [String] = [], customTitle: String? = nil,
        folder: URL = MenuBarFixtures.tempDir()
    ) -> RecordingEntry {
        RecordingEntry(
            id: id, recordingStart: start, folderURL: folder,
            durationSeconds: refined ? 60 : 0,
            speakers: speakers.map {
                RecordingSpeaker(label: $0, speakerId: nil, isMicrophone: $0 == "You")
            },
            isRefined: refined, customTitle: customTitle)
    }

    static func makeModel(
        entries: [RecordingEntry],
        status: RecordingStatus = .idle,
        navigation: AppNavigation = AppNavigation()
    ) -> RecordingsPaneModel {
        let model = RecordingsPaneModel(
            scanner: RecordingsScanner(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            queueVM: RefinementJobQueueViewModel(
                queue: RefinementJobQueue(
                    store: RefinementJobStore(directory: MenuBarFixtures.tempDir()),
                    runJob: { _ in })),
            recording: RecordingViewModel(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            navigation: navigation,
            now: { Self.now })
        model.entriesOverride = entries
        model.statusOverride = status
        return model
    }

    // MARK: Day sections (§4.1)

    @Test("day keys: today / yesterday / weekday-within-week / older")
    func dayKeys() {
        #expect(RecordingsPaneModel.dayKey(for: Self.date(daysAgo: 0), now: Self.now) == .today)
        #expect(RecordingsPaneModel.dayKey(for: Self.date(daysAgo: 1), now: Self.now) == .yesterday)
        let d3 = Self.date(daysAgo: 3)
        #expect(RecordingsPaneModel.dayKey(for: d3, now: Self.now)
                == .weekday(Calendar.current.startOfDay(for: d3)))
        let d9 = Self.date(daysAgo: 9)
        #expect(RecordingsPaneModel.dayKey(for: d9, now: Self.now)
                == .older(Calendar.current.startOfDay(for: d9)))
    }

    @Test("groups preserve newest-first order and split on day boundaries")
    func grouping() {
        let model = Self.makeModel(entries: [
            Self.entry(id: "rec_a", start: Self.date(daysAgo: 0, hour: 14)),
            Self.entry(id: "rec_b", start: Self.date(daysAgo: 0, hour: 9)),
            Self.entry(id: "rec_c", start: Self.date(daysAgo: 1)),
            Self.entry(id: "rec_d", start: Self.date(daysAgo: 9)),
        ])
        let groups = model.groups
        #expect(groups.map(\.key) == [
            .today, .yesterday,
            .older(Calendar.current.startOfDay(for: Self.date(daysAgo: 9))),
        ])
        #expect(groups[0].rows.map(\.id) == ["rec_a", "rec_b"])
    }

    // MARK: Filter (§4.1)

    @Test("filter matches custom title, speaker label, and date words; misses show no rows")
    func filtering() {
        let model = Self.makeModel(entries: [
            Self.entry(id: "rec_a", start: Self.date(daysAgo: 0),
                       speakers: ["You", "Dana"], customTitle: "Platform sync"),
            Self.entry(id: "rec_b", start: Self.date(daysAgo: 1)),
        ])
        model.filterText = "platform"
        #expect(model.groups.flatMap(\.rows).map(\.id) == ["rec_a"])
        model.filterText = "dana"
        #expect(model.groups.flatMap(\.rows).map(\.id) == ["rec_a"])
        // Date-word match is deterministic under the injected clock: rec_b
        // (daysAgo: 1) has the relative title "Yesterday at …".
        model.filterText = "yesterday"
        #expect(model.groups.flatMap(\.rows).map(\.id) == ["rec_b"])
        model.filterText = "zzz-no-match"
        #expect(model.groups.isEmpty)
    }

    // MARK: Row title composition (§4.1)

    @Test("title parts: named rows caption the time+duration; unnamed rows dim the duration")
    func titleComposition() {
        let start = Self.date(daysAgo: 0, hour: 7)
        let time = start.formatted(date: .omitted, time: .shortened)

        let named = Self.makeModel(entries: [
            Self.entry(id: "rec_n", start: start, customTitle: "Platform sync")
        ]).rows[0]
        #expect(named.titleText == "Platform sync")
        #expect(named.titleDurationText == nil)
        #expect(named.captionText == "\(time) · 1:00")

        let unnamed = Self.makeModel(entries: [
            Self.entry(id: "rec_u", start: start)
        ]).rows[0]
        #expect(unnamed.titleText == time)
        #expect(unnamed.titleDurationText == "1:00")
        #expect(unnamed.captionText == nil)

        // Unrefined rows carry durationSeconds == 0 — no duration to show.
        let unrefined = Self.makeModel(entries: [
            Self.entry(id: "rec_r", start: start, refined: false)
        ]).rows[0]
        #expect(unrefined.titleText == time)
        #expect(unrefined.titleDurationText == nil)
    }

    @Test("the live row is exempt from filtering")
    func liveRowFilterExempt() {
        let model = Self.makeModel(
            entries: [Self.entry(id: "rec_old", start: Self.date(daysAgo: 1))],
            status: .recording(id: "rec_live", startedAt: Self.now))
        model.filterText = "zzz-no-match"
        #expect(model.groups.flatMap(\.rows).map(\.id) == ["rec_live"])
    }

    // MARK: Live row synthesis (§4.1)

    @Test("recording status synthesizes a live row that dedupes once the scanner has the id")
    func liveRowSynthesisAndDedup() {
        let startedAt = Self.date(daysAgo: 0, hour: 14)
        let model = Self.makeModel(
            entries: [Self.entry(id: "rec_x", start: Self.date(daysAgo: 1))],
            status: .recording(id: "rec_live", startedAt: startedAt))
        var rows = model.rows
        #expect(rows.first?.id == "rec_live")
        #expect(rows.first?.isLive == true)
        #expect(rows.count == 2)

        // Scanner now returns the same id — no duplicate row, still live-badged.
        model.entriesOverride = [
            Self.entry(id: "rec_live", start: startedAt, refined: false),
            Self.entry(id: "rec_x", start: Self.date(daysAgo: 1)),
        ]
        rows = model.rows
        #expect(rows.map(\.id) == ["rec_live", "rec_x"])
        #expect(rows.first?.isLive == true)
    }

    @Test("live row disappears when the status leaves .recording")
    func liveRowRemoval() {
        let model = Self.makeModel(entries: [], status: .recording(id: "rec_live", startedAt: Self.now))
        #expect(model.rows.count == 1)
        model.statusOverride = .idle
        #expect(model.rows.isEmpty)
    }

    // MARK: Auto-select (§4.1)

    @Test("nil or stale selection falls back to the newest row; a valid selection is never moved")
    func autoSelect() {
        let nav = AppNavigation()
        let model = Self.makeModel(entries: [
            Self.entry(id: "rec_new", start: Self.date(daysAgo: 0)),
            Self.entry(id: "rec_old", start: Self.date(daysAgo: 1)),
        ], navigation: nav)
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_new")

        nav.selectedRecordingID = "rec_old"
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_old")

        nav.selectedRecordingID = "rec_gone"
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_new")
    }

    @Test("recording id derivation is shared between RecordPlan and the scanner (spec §12)")
    func idDerivationUnified() throws {
        // Both sides call RecordingFolder.recordingId(forName:) on the folder
        // basename — pin the equivalence so neither side can drift.
        let name = RecordingViewModel.recordingFolderName(at: Self.now)
        #expect(RecordingFolder.recordingId(forName: name).hasPrefix("rec_"))
        // decodeUnrefined uses the identical call — see RecordingEntry.swift.
        let root = MenuBarFixtures.tempDir()
        let folder = try MenuBarFixtures.makeUnrefinedRecordingFolder(root: root, name: name)
        let entry = RecordingEntry.decodeUnrefined(folderURL: folder)
        #expect(entry?.id == RecordingFolder.recordingId(forName: name))
    }

    // MARK: Refinement job helper

    static func job(
        _ id: String, recordingId: String, state: RefinementJobState
    ) -> RefinementJob {
        RefinementJob(
            id: id, recordingId: recordingId,
            folderURL: MenuBarFixtures.tempDir(),
            modelName: "base", modelSHA256: "deadbeef",
            trigger: .manual, enqueuedAt: Self.now, state: state)
    }

    // MARK: Badges (§4.1)

    @Test("badge precedence: running beats queued beats recent beats intrinsic")
    func badgePrecedence() {
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let model = Self.makeModel(entries: [e])
        model.runningOverride = .some(Self.job(
            "job_1", recordingId: "rec_a",
            state: .running(stage: .diarizing, stepsCompleted: 1, stepsTotal: 4,
                            regionIndex: nil, regionsTotal: nil)))
        guard case .refining = model.rows[0].badge else {
            Issue.record("expected .refining, got \(model.rows[0].badge)"); return
        }

        model.runningOverride = .some(nil)
        model.queuedOverride = [Self.job("job_2", recordingId: "rec_a", state: .queued)]
        #expect(model.rows[0].badge == .queued)

        model.queuedOverride = []
        model.recentOverride = [Self.job(
            "job_3", recordingId: "rec_a",
            state: .failed(errorClass: "model_load_failed", retryAvailable: true))]
        guard case .failed = model.rows[0].badge else {
            Issue.record("expected .failed, got \(model.rows[0].badge)"); return
        }
    }

    @Test("refined row shows the steady check; unrefined shows notYetRefined; cancelled falls through")
    func intrinsicBadges() {
        let refined = Self.entry(id: "rec_r", start: Self.date(daysAgo: 0))
        let raw = Self.entry(id: "rec_u", start: Self.date(daysAgo: 0), refined: false)
        let model = Self.makeModel(entries: [refined, raw])
        #expect(model.rows[0].badge == .refined)
        #expect(model.rows[1].badge == .notYetRefined)

        model.recentOverride = [Self.job("job_c", recordingId: "rec_r", state: .cancelled)]
        #expect(model.rows[0].badge == .refined)  // cancelled → intrinsic
    }

    // MARK: Steady refined check (§4.1, QA round 5)

    @Test("the refined check is steady — selecting the row does not clear it")
    func refinedCheckSurvivesSelection() {
        let nav = AppNavigation()
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let model = Self.makeModel(entries: [e], navigation: nav)
        #expect(model.rows[0].badge == .refined)

        model.select("rec_a")
        #expect(model.rows[0].badge == .refined)
    }

    @Test("a completed job shows the check before the scanner re-reads the folder")
    func completedJobBridgesScannerLag() {
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0), refined: false)
        let model = Self.makeModel(entries: [e])
        #expect(model.rows[0].badge == .notYetRefined)

        model.recentOverride = [Self.job(
            "job_1", recordingId: "rec_a",
            state: .completed(durationSeconds: 60, speakerCount: 2))]
        #expect(model.rows[0].badge == .refined)
    }

    // MARK: Rename round-trip (§4.1)

    @Test("rename writes the sidecar; clearing restores the default")
    func renameRoundTrip() async throws {
        let folder = MenuBarFixtures.tempDir()
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0), folder: folder)
        let model = Self.makeModel(entries: [e])
        await model.rename(recordingId: "rec_a", to: "  Board\nreview ")
        #expect(RecordingTitleStore.read(folderURL: folder) == "Board review")

        await model.rename(recordingId: "rec_a", to: "   ")
        #expect(RecordingTitleStore.read(folderURL: folder) == nil)
    }

    // MARK: Per-recording mic-diarization stamp (PT-R142)

    @Test("setDiarizeMic writes the options.json sidecar; toggling off reverts it")
    func setDiarizeMicRoundTrip() async throws {
        let folder = MenuBarFixtures.tempDir()
        let e = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0), folder: folder)
        let model = Self.makeModel(entries: [e])

        #expect(RecordingOptions.read(from: folder).diarizeMic == false)
        await model.setDiarizeMic(recordingId: "rec_a", enabled: true)
        #expect(RecordingOptions.read(from: folder).diarizeMic == true)

        await model.setDiarizeMic(recordingId: "rec_a", enabled: false)
        #expect(RecordingOptions.read(from: folder).diarizeMic == false)
    }

    @Test("setDiarizeMic is a no-op for a live recording (engine ignores the sidecar mid-recording)")
    func setDiarizeMicSkipsLiveRow() async throws {
        let model = Self.makeModel(
            entries: [], status: .recording(id: "rec_live", startedAt: Self.now))
        // The live row's folder is the recording view model's in-progress
        // folder; it has no sidecar. A no-op leaves nothing to assert beyond
        // not crashing and not throwing an action error.
        await model.setDiarizeMic(recordingId: "rec_live", enabled: true)
        #expect(model.lastActionError == nil)
    }

    // MARK: Move to Trash (§4.1)

    @Test("moveToTrash recycles the folder and the selection falls back to newest")
    func moveToTrash() async {
        let nav = AppNavigation()
        var trashed: [URL] = []
        let a = Self.entry(id: "rec_a", start: Self.date(daysAgo: 0))
        let b = Self.entry(id: "rec_b", start: Self.date(daysAgo: 1))
        let model = RecordingsPaneModel(
            scanner: RecordingsScanner(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            queueVM: RefinementJobQueueViewModel(
                queue: RefinementJobQueue(
                    store: RefinementJobStore(directory: MenuBarFixtures.tempDir()),
                    runJob: { _ in })),
            recording: RecordingViewModel(settings: MenuBarSettings(
                defaults: UserDefaults(suiteName: "pt-test-\(UUID().uuidString)")!)),
            navigation: nav,
            now: { Self.now },
            trashItem: { trashed.append($0) })
        model.entriesOverride = [a, b]
        nav.selectedRecordingID = "rec_a"

        await model.moveToTrash(recordingId: "rec_a")
        #expect(trashed == [a.folderURL])
        // entriesOverride still contains rec_a (no real scan ran) — drop it
        // the way a refresh would, then the fallback picks the newest left.
        model.entriesOverride = [b]
        model.ensureSelection()
        #expect(nav.selectedRecordingID == "rec_b")
    }

    // MARK: Failure humanization

    @Test("friendlyFailure humanizes known error classes and falls back to a generic line for unknown ones")
    func friendlyFailureMapping() {
        // Pinned against the humanization table (originally lifted from the
        // since-deleted RefinementsListView's JobRow.friendly(_:)). Known
        // classes map to a phrase; unknown classes fall back to the generic
        // line.
        #expect(RecordingsPaneModel.friendlyFailure("modelMissing")
                == "the model could not be loaded")
        #expect(RecordingsPaneModel.friendlyFailure("modelChecksum")
                == "the model could not be loaded")
        #expect(RecordingsPaneModel.friendlyFailure("diarizeCrashed")
                == "speaker analysis failed")
        #expect(RecordingsPaneModel.friendlyFailure("transcribeFailed")
                == "transcription failed")
        // `missingDependency` is the real producer string
        // (`RefinementJobError.errorClass` for .pythonNotFound / .launchFailed).
        #expect(RecordingsPaneModel.friendlyFailure("missingDependency")
                == "a required component is missing")
        #expect(RecordingsPaneModel.friendlyFailure("totally_unknown_class")
                == "an internal error")
    }
}
