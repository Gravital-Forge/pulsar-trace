import SwiftUI
import PulsarTraceEngine
import PulsarTraceMenuBar

/// The "Refinements" sidebar pane — shows running, queued, and recently
/// completed refinement jobs with live progress and cancel controls (E2).
struct RefinementsListView: View {
    @Environment(RefinementJobQueueViewModel.self) private var queue

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
                        JobRow(job: job, allowCancel: false) {}
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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayId).font(.body.monospaced())
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let fraction = job.state.progressFraction {
                ProgressView(value: fraction).frame(width: 120)
            }
            if allowCancel {
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.borderless)
            }
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
        case .failed(let errorClass, let retryAvailable):
            return retryAvailable ? "Failed (\(errorClass)) · retryable" : "Failed (\(errorClass))"
        case .cancelled:
            return "Cancelled"
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
