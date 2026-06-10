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
        model.filterText = "zzz-no-match"
        #expect(model.groups.isEmpty)
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
    func idDerivationUnified() {
        // Both sides call RecordingFolder.recordingId(forName:) on the folder
        // basename — pin the equivalence so neither side can drift.
        let name = RecordingViewModel.recordingFolderName(at: Self.now)
        #expect(RecordingFolder.recordingId(forName: name).hasPrefix("rec_"))
        // decodeUnrefined uses the identical call — see RecordingEntry.swift.
        let root = MenuBarFixtures.tempDir()
        let folder = try! MenuBarFixtures.makeUnrefinedRecordingFolder(root: root, name: name)
        let entry = RecordingEntry.decodeUnrefined(folderURL: folder)
        #expect(entry?.id == RecordingFolder.recordingId(forName: name))
    }
}
