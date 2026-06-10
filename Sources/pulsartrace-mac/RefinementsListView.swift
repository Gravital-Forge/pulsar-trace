import SwiftUI
import PulsarTraceEngine
import PulsarTraceMenuBar

/// The "Refinements" sidebar pane — shows running, queued, and recently
/// completed refinement jobs with live progress and cancel controls (E2).
struct RefinementsListView: View {
    @Environment(RefinementJobQueueViewModel.self) private var queue
    @Environment(MenuBarSettings.self) private var settings

    var body: some View {
        List {
            if let running = queue.running {
                Section("Running") {
                    JobRow(job: running, allowCancel: false) {}
                }
            }
            if !queue.queued.isEmpty {
                Section("Queued") {
                    ForEach(queue.queued) { job in
                        JobRow(job: job, allowCancel: true) {
                            Task { await queue.cancel(recordingId: job.recordingId) }
                        }
                    }
                }
            }
            if !queue.recent.isEmpty {
                Section("Recent") {
                    ForEach(queue.recent) { job in
                        // The job descriptor carries everything a re-enqueue
                        // needs (folderURL + recordingId); the model is
                        // re-resolved from the current setting, same as the
                        // recordings list's Refine button.
                        JobRow(job: job, allowCancel: false, onCancel: {}) {
                            Task {
                                await queue.enqueueManual(
                                    folderURL: job.folderURL,
                                    recordingId: job.recordingId,
                                    refineModelName: settings.refineModelName)
                            }
                        }
                    }
                }
            }
            if queue.running == nil && queue.queued.isEmpty && queue.recent.isEmpty {
                EmptyStateRow()
            }
        }
        // Polling is started once by AppEnvironment.bootstrap for the whole
        // process lifetime — the menubar dropdown and the recordings list
        // both bind to this VM, so they need fresh data even when this pane
        // is not visible. The Refresh button forces an immediate refresh
        // instead of waiting for the next 250 ms tick.
        //
        // A window toolbar so this pane's split-view chrome (corner rounding,
        // sidebar extent) matches the Recordings and Speakers panes — those
        // carry a toolbar; a pane without one renders different chrome.
        // See SettingsView.swift for the same rationale.
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await queue.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh refinement job list")
            }
        }
    }
}

private struct JobRow: View {
    let job: RefinementJob
    let allowCancel: Bool
    let onCancel: () -> Void
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayId).font(.body.monospaced())
                stateLabel
            }
            Spacer()
            if let fraction = job.state.progressFraction {
                ProgressView(value: fraction).frame(width: 120)
            }
            if allowCancel {
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.borderless)
            }
            // Retry only when the queue marked the failure transient —
            // permanent classes (missing model, bad checksum) get no button.
            if case .failed(_, retryAvailable: true) = job.state, let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderless)
            }
        }
    }

    /// The state caption. A failed row shows humanized copy but keeps the
    /// raw stable `errorClass` reachable via tooltip for bug reports.
    @ViewBuilder
    private var stateLabel: some View {
        let caption = Text(stateText).font(.caption).foregroundStyle(.secondary)
        if case .failed(let errorClass, _) = job.state {
            caption.help(errorClass)
        } else {
            caption
        }
    }

    /// Strip the `rec_` storage prefix at display time. The prefix is a stable
    /// database key and must not be removed from any non-display site.
    private var displayId: String {
        job.recordingId.hasPrefix("rec_")
            ? String(job.recordingId.dropFirst(4))
            : job.recordingId
    }

    private var stateText: String {
        switch job.state {
        case .queued:
            return "Queued"
        case .running(let stage, let done, let total, let regionIndex, let regionsTotal):
            if let regionIndex, let regionsTotal {
                return "\(stage.displayName) (\(done + 1)/\(total)) · region \(regionIndex)/\(regionsTotal)"
            }
            return "\(stage.displayName) (\(done + 1)/\(total))"
        case .paused(let reason, let lastStage):
            return "Paused (\(reason.displayName)) at \(lastStage.displayName)"
        case .completed(let seconds, let speakerCount):
            let speakerWord = speakerCount == 1 ? "speaker" : "speakers"
            return "Done · \(Int(seconds.rounded()))s · \(speakerCount) \(speakerWord)"
        case .failed(let errorClass, _):
            return "Failed — \(Self.friendly(errorClass))"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Humanize a stable `errorClass` identifier (`RefinementJobError
    /// .errorClass`) for the row caption. The raw class stays reachable via
    /// `.help` on the caption; unknown classes fall back to a generic line.
    private static func friendly(_ errorClass: String) -> String {
        switch errorClass {
        case "modelMissing", "modelChecksum": return "the model could not be loaded"
        case "diarizeCrashed":                return "speaker analysis failed"
        case "transcribeFailed":              return "transcription failed"
        default:                              return "an internal error"
        }
    }
}

private struct EmptyStateRow: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No refinements in flight.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
