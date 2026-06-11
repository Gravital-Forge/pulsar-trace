import Foundation
import PulsarTraceEngine

/// Day-section key for the recordings list (§4.1). Category-level on purpose
/// so tests assert structure, not locale strings.
public enum DayKey: Equatable, Hashable, Sendable {
    case today
    case yesterday
    /// Within the last week (but not today/yesterday) — "Monday, June 8".
    case weekday(Date)
    /// Older — "June 3, 2026".
    case older(Date)

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .weekday(let day):
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .older(let day):
            return day.formatted(.dateTime.month(.wide).day().year())
        }
    }
}

/// One row in the recordings list — a scanned recording or the synthesized
/// in-progress row (§4.1).
public struct RecordingRow: Identifiable, Equatable {

    /// Exceptional-only status badge (§4.1) — `.none` for a steady refined
    /// recording. Queue state wins over the intrinsic refined flag,
    /// preserving the documented `RefineStatusIcon` precedence
    /// (running > queued > recent > intrinsic).
    public enum Badge: Equatable {
        case recordingNow(startedAt: Date)
        case queued
        case refining(fraction: Double?, stageName: String)
        case failed(friendlyMessage: String, errorClass: String, retryable: Bool)
        case notYetRefined
        case justRefined
        case none
    }

    public let entry: RecordingEntry
    public let isLive: Bool
    public let badge: Badge
    public var id: String { entry.id }

    /// Row title: the custom title when one is set, else time (+ duration
    /// when known — unrefined rows carry `durationSeconds == 0`).
    public var titleText: String { entry.customTitle ?? timeAndDuration }

    /// Caption beneath a custom title; `nil` when the title already IS the
    /// time + duration line.
    public var captionText: String? { entry.customTitle != nil ? timeAndDuration : nil }

    private var timeAndDuration: String {
        let time = entry.recordingStart.formatted(date: .omitted, time: .shortened)
        guard entry.durationSeconds > 0 else { return time }
        return "\(time) · \(RecordingEntry.formatDuration(entry.durationSeconds))"
    }
}

public struct RecordingDayGroup: Identifiable, Equatable {
    public let key: DayKey
    public let rows: [RecordingRow]
    public var id: DayKey { key }
}

/// Composes scanner entries + recording status + queue state + filter text
/// into the day-sectioned row models of the Recordings pane (§4.1): live-row
/// synthesis & dedup, badge derivation (incl. the transient just-refined
/// check), filtering, auto-select rules, rename, move-to-Trash.
@MainActor
@Observable
public final class RecordingsPaneModel {

    /// Inline filter text ("Filter by title, speaker, or date").
    public var filterText: String = ""

    /// Last rename/trash failure — dismissible banner in the list column.
    public private(set) var lastActionError: String?

    private let scanner: RecordingsScanner
    private let queueVM: RefinementJobQueueViewModel
    private let recording: RecordingViewModel
    private let navigation: AppNavigation
    private let now: () -> Date
    private let trashItem: (URL) throws -> Void

    /// Completed job ids whose transient green check was acknowledged —
    /// either by selecting the row, or because the row was already selected
    /// when its refine completed (§4.1). No timer, no clock: badge clearing
    /// also happens naturally when the job ages out of `queueVM.recent`.
    private var acknowledgedJobIDs: Set<String> = []

    /// Test seams — production leaves these nil and reads the real scanner /
    /// recording VM.
    var entriesOverride: [RecordingEntry]?
    var statusOverride: RecordingStatus?

    /// Test seams for queue state. `runningOverride == .some(nil)` forces
    /// "no running job"; a nil outer optional defers to the real queue VM.
    var runningOverride: RefinementJob??
    var queuedOverride: [RefinementJob]?
    var recentOverride: [RefinementJob]?

    public init(
        scanner: RecordingsScanner,
        queueVM: RefinementJobQueueViewModel,
        recording: RecordingViewModel,
        navigation: AppNavigation,
        now: @escaping () -> Date = { Date() },
        trashItem: ((URL) throws -> Void)? = nil
    ) {
        self.scanner = scanner
        self.queueVM = queueVM
        self.recording = recording
        self.navigation = navigation
        self.now = now
        self.trashItem = trashItem ?? { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private var entries: [RecordingEntry] { entriesOverride ?? scanner.recordings }
    private var status: RecordingStatus { statusOverride ?? recording.status }

    private var runningJob: RefinementJob? { runningOverride ?? queueVM.running }
    private var queuedJobs: [RefinementJob] { queuedOverride ?? queueVM.queued }
    private var recentJobs: [RefinementJob] { recentOverride ?? queueVM.recent }

    // MARK: - Rows

    /// All rows, newest first: the synthesized live row (while
    /// `status == .recording`) followed by scanned entries. The live row is
    /// built from the VM's status + `liveMarkdownURL` — no dependence on the
    /// scanner noticing the new folder. Once a scan returns an entry with the
    /// same id, that entry backs the row (dedup — ids are stable across
    /// refine).
    public var rows: [RecordingRow] {
        var out: [RecordingRow] = []
        var liveID: String?
        if case .recording(let id, let startedAt) = status {
            liveID = id
            let entry = entries.first { $0.id == id }
                ?? synthesizedEntry(id: id, startedAt: startedAt)
            out.append(RecordingRow(
                entry: entry, isLive: true,
                badge: .recordingNow(startedAt: startedAt)))
        }
        for entry in entries where entry.id != liveID {
            out.append(RecordingRow(entry: entry, isLive: false, badge: badge(for: entry)))
        }
        return out
    }

    private func synthesizedEntry(id: String, startedAt: Date) -> RecordingEntry {
        let folder = recording.liveMarkdownURL?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        return RecordingEntry(
            id: id, recordingStart: startedAt, folderURL: folder,
            durationSeconds: 0, speakers: [], isRefined: false,
            customTitle: RecordingTitleStore.read(folderURL: folder))
    }

    /// Day-sectioned, filter-applied rows. The live row is exempt from
    /// filtering while recording (§4.1).
    public var groups: [RecordingDayGroup] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let reference = now()
        let visible = rows.filter { row in
            row.isLive || query.isEmpty
                || Self.matches(row.entry, query: query, now: reference)
        }
        var grouped: [(DayKey, [RecordingRow])] = []
        // Rows are newest-first (the scanner sorts; the live row prepends), so
        // equal day keys are always adjacent — a single forward pass that
        // merges into the last group suffices, no full grouping dictionary.
        for row in visible {
            let key = Self.dayKey(for: row.entry.recordingStart, now: reference)
            if grouped.last?.0 == key {
                grouped[grouped.count - 1].1.append(row)
            } else {
                grouped.append((key, [row]))
            }
        }
        return grouped.map { RecordingDayGroup(key: $0.0, rows: $0.1) }
    }

    static func dayKey(for date: Date, now: Date, calendar: Calendar = .current) -> DayKey {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let day = calendar.startOfDay(for: date)
        if date < now,
           let weekAgo = calendar.date(
               byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           day >= weekAgo {
            return .weekday(day)
        }
        return .older(day)
    }

    /// Case-insensitive match over the custom title, the relative date title
    /// ("Yesterday at …" — resolved against the injected `now` so date-word
    /// queries are deterministic), the folder basename (the raw date string),
    /// and speaker labels. Custom titles matching is what makes the filter
    /// genuinely useful.
    static func matches(_ entry: RecordingEntry, query: String, now: Date) -> Bool {
        let q = query.lowercased()
        if let custom = entry.customTitle, custom.lowercased().contains(q) { return true }
        if RecordingEntry.displayTitle(for: entry.recordingStart, relativeTo: now)
            .lowercased().contains(q) { return true }
        if entry.displayName.lowercased().contains(q) { return true }
        if entry.recordingStart
            .formatted(date: .abbreviated, time: .shortened)
            .lowercased().contains(q) { return true }
        return entry.speakers.contains { $0.label.lowercased().contains(q) }
    }

    // MARK: - Selection (§4.1)

    /// Select a row — selecting *is* opening. Acknowledges the transient
    /// just-refined badge for that recording.
    public func select(_ recordingId: String?) {
        navigation.selectedRecordingID = recordingId
        if let recordingId { acknowledgeCompleted(recordingId: recordingId) }
    }

    /// Auto-select rule: when the selection is nil or its row no longer
    /// exists, select the newest row so the detail is never blank. NEVER
    /// moves an existing valid selection (a hotkey-started recording must
    /// not steal the reading position — §6).
    public func ensureSelection() {
        let ids = rows.map(\.id)
        if let current = navigation.selectedRecordingID, ids.contains(current) { return }
        navigation.selectedRecordingID = ids.first
    }

    // MARK: - Badges (Task 4 adds tests; precedence: running > queued > recent > intrinsic)

    func badge(for entry: RecordingEntry) -> RecordingRow.Badge {
        if let running = runningJob, running.recordingId == entry.id {
            return .refining(
                fraction: running.state.progressFraction,
                stageName: Self.stageName(of: running.state))
        }
        if queuedJobs.contains(where: { $0.recordingId == entry.id }) {
            return .queued
        }
        if let recent = recentJobs.first(where: { $0.recordingId == entry.id }) {
            switch recent.state {
            case .completed:
                if !acknowledgedJobIDs.contains(recent.id) { return .justRefined }
            case .failed(let errorClass, let retryable):
                return .failed(
                    friendlyMessage: Self.friendlyFailure(errorClass),
                    errorClass: errorClass, retryable: retryable)
            default:
                break  // cancelled etc. fall through to the intrinsic flag
            }
        }
        return entry.isRefined ? .none : .notYetRefined
    }

    static func stageName(of state: RefinementJobState) -> String {
        if case .running(let stage, _, _, _, _) = state { return stage.displayName }
        return ""
    }

    /// Humanize a stable `errorClass` identifier (`RefinementJobError
    /// .errorClass`) into list-row copy. Known classes map to a short phrase;
    /// unknown classes fall back to a generic line. The raw class stays
    /// reachable via the badge tooltip for bug reports.
    public static func friendlyFailure(_ errorClass: String) -> String {
        switch errorClass {
        case "modelMissing", "modelChecksum": return "the model could not be loaded"
        case "diarizeCrashed":                return "speaker analysis failed"
        case "transcribeFailed":              return "transcription failed"
        default:                              return "an internal error"
        }
    }

    /// Called (via AppEnvironment) when refinement jobs reach a terminal
    /// state. A completion for the recording the user is *already looking
    /// at* never shows the row badge — the detail's completion banner is the
    /// signal there (§4.1).
    public func noteJobsTerminated(_ jobs: [RefinementJob]) {
        for job in jobs {
            if case .completed = job.state,
               navigation.selectedRecordingID == job.recordingId {
                acknowledgedJobIDs.insert(job.id)
            }
        }
        // Prune so the set can't grow unboundedly: a completed job is in
        // `recent` (it arrived there this tick), so once it ages out its id is
        // dead weight — intersecting with the live recent ids drops it.
        acknowledgedJobIDs.formIntersection(Set(recentJobs.map(\.id)))
    }

    private func acknowledgeCompleted(recordingId: String) {
        for job in recentJobs where job.recordingId == recordingId {
            if case .completed = job.state { acknowledgedJobIDs.insert(job.id) }
        }
    }

    // MARK: - Actions (§4.1; tests in the next task)

    /// Rename via the `title.txt` sidecar (§4.1); a blank title clears back
    /// to the date default. The folder basename is never renamed.
    public func rename(recordingId: String, to rawTitle: String) async {
        // No `!row.isLive` guard (unlike moveToTrash): renaming the
        // in-progress row is allowed — harmless, the engine ignores the
        // sidecar and never reads `title.txt` (spec §4.1).
        guard let row = rows.first(where: { $0.id == recordingId }) else { return }
        do {
            try RecordingTitleStore.write(rawTitle, folderURL: row.entry.folderURL)
            lastActionError = nil
        } catch {
            lastActionError = "Could not save the title: \(error.localizedDescription)"
            return
        }
        await scanner.refresh()
    }

    /// Move a recording folder to the Trash (§4.1) — the Trash itself is the
    /// undo. Selection falls back per the auto-select rule.
    public func moveToTrash(recordingId: String) async {
        guard let row = rows.first(where: { $0.id == recordingId }), !row.isLive
        else { return }
        do {
            try trashItem(row.entry.folderURL)
            lastActionError = nil
        } catch {
            lastActionError =
                "Could not move the recording to the Trash: \(error.localizedDescription)"
            return
        }
        if navigation.selectedRecordingID == recordingId {
            navigation.selectedRecordingID = nil
        }
        await scanner.refresh()
        ensureSelection()
    }

    public func clearActionError() { lastActionError = nil }
}
