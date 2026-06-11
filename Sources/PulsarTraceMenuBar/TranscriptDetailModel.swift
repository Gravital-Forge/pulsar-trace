import Foundation
import PulsarTraceEngine

/// Picks the transcript source and banner for the selected recording row —
/// the §4.2 decision table — and owns the async file load with the
/// pending-refined-content gate (a refine completion never swaps content
/// under the user).
@MainActor
@Observable
public final class TranscriptDetailModel {

    public enum Content: Equatable {
        /// No selection / no recordings — ContentUnavailableView.
        case empty
        /// Live row — render `liveWatcher.lines` with auto-scroll.
        case live
        case loading
        case lines([String])
        /// File missing — "no transcript yet" placeholder.
        case placeholder
        /// File exists but could not be read — loadError banner + Retry.
        case unreadable
    }

    public enum Banner: Equatable {
        case none
        case queued
        case refining(fraction: Double?, stageName: String)
        case refineCompleted
        case unrefined
        case failed(friendlyMessage: String, errorClass: String, retryable: Bool)
        case loadError
    }

    /// Queue-state seam for tests; production derives from `queueVM` (same
    /// override pattern as `RecordingsPaneModel`).
    public enum QueuePosture: Equatable {
        case idle
        case queued
        case refining(fraction: Double?, stageName: String)
        case failed(errorClass: String, retryable: Bool)
    }
    var queueOverride: QueuePosture?

    public private(set) var content: Content = .empty
    /// The row the detail is showing (fresh snapshot on every list recompute).
    public private(set) var shown: RecordingRow?
    /// Set when a refine completed for the on-screen recording while
    /// readable content was loaded (§4.2) — the banner offers "Show refined
    /// transcript" instead of reloading.
    public private(set) var pendingRefinedContent = false

    private let queueVM: RefinementJobQueueViewModel
    /// Exposed so the view renders live lines through the model's owner.
    public let liveWatcher: LiveTranscriptWatcher
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    public init(
        queueVM: RefinementJobQueueViewModel,
        liveWatcher: LiveTranscriptWatcher
    ) {
        self.queueVM = queueVM
        self.liveWatcher = liveWatcher
    }

    // MARK: - Selection

    /// Show a row. Same id → only the row snapshot updates (badge/entry
    /// freshness); the content is NOT reloaded under the user. A different
    /// id (or a live↔file flip for the same id) loads the new source.
    public func show(_ row: RecordingRow?) {
        let previous = shown
        shown = row
        guard row?.id != previous?.id || row?.isLive != previous?.isLive else {
            return
        }
        pendingRefinedContent = false
        loadTask?.cancel()
        guard let row else {
            content = .empty
            return
        }
        if row.isLive {
            content = .live
            return
        }
        reload()
    }

    /// Re-read the file source (explicit triggers only: selection change,
    /// "Show refined transcript", load-error Retry, completion-over-placeholder).
    public func reload() {
        guard let row = shown, !row.isLive else { return }
        pendingRefinedContent = false
        loadGeneration += 1
        let generation = loadGeneration
        let finalURL = row.entry.finalURL
        let liveURL = row.entry.liveURL
        content = .loading
        loadTask = Task { [weak self] in
            // Three-way result (lifted from the retired RecordedTranscriptSheet):
            // [] = no file, nil = unreadable, lines = success.
            let result: [String]? = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let url = fm.fileExists(atPath: finalURL.path) ? finalURL : liveURL
                guard fm.fileExists(atPath: url.path) else { return [] }
                guard let text = try? String(contentsOf: url, encoding: .utf8)
                else { return nil }
                return text.components(separatedBy: "\n")
            }.value
            guard let self, self.loadGeneration == generation else { return }
            switch result {
            case nil: self.content = .unreadable
            case .some(let lines) where lines.allSatisfy(\.isEmpty):
                self.content = .placeholder
            case .some(let lines): self.content = .lines(lines)
            }
        }
    }

    /// The "Show refined transcript" banner action (§4.2).
    public func showRefinedTranscript() { reload() }

    /// Awaitable load completion for deterministic tests.
    public func awaitLoadForTesting() async {
        await loadTask?.value
    }

    // MARK: - Banner (§4.2 decision table)

    public var banner: Banner {
        guard let row = shown, !row.isLive else { return .none }
        if case .unreadable = content { return .loadError }
        switch queuePosture(for: row.id) {
        case .refining(let fraction, let stage):
            return .refining(fraction: fraction, stageName: stage)
        case .queued:
            return .queued
        case .failed(let errorClass, let retryable):
            return .failed(
                friendlyMessage: RecordingsPaneModel.friendlyFailure(errorClass),
                errorClass: errorClass, retryable: retryable)
        case .idle:
            break
        }
        if pendingRefinedContent { return .refineCompleted }
        if !row.entry.isRefined { return .unrefined }
        return .none
    }

    private func queuePosture(for recordingId: String) -> QueuePosture {
        if let override = queueOverride { return override }
        if let running = queueVM.running, running.recordingId == recordingId {
            return .refining(
                fraction: running.state.progressFraction,
                stageName: RecordingsPaneModel.stageName(of: running.state))
        }
        if queueVM.queued.contains(where: { $0.recordingId == recordingId }) {
            return .queued
        }
        if let recent = queueVM.recent.first(where: { $0.recordingId == recordingId }),
           case .failed(let errorClass, let retryable) = recent.state {
            return .failed(errorClass: errorClass, retryable: retryable)
        }
        return .idle
    }

    // MARK: - Refine-completion gate (§4.2)

    public func noteJobsTerminated(_ jobs: [RefinementJob]) {
        guard let row = shown, !row.isLive else { return }
        let completedForShown = jobs.contains { job in
            guard job.recordingId == row.id else { return false }
            if case .completed = job.state { return true }
            return false
        }
        guard completedForShown else { return }
        switch content {
        case .lines:
            pendingRefinedContent = true
        case .placeholder, .unreadable, .empty, .loading:
            reload()
        case .live:
            break
        }
    }
}
