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
        .task { queue.startPolling() }
        .onDisappear { queue.stopPolling() }
    }
}

private struct JobRow: View {
    let job: RefinementJob
    let allowCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.recordingId).font(.body.monospaced())
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

    private var stateText: String {
        switch job.state {
        case .queued:
            return "Queued"
        case .running(let stage, let done, let total, let regionIndex, let regionsTotal):
            if let regionIndex, let regionsTotal {
                return "\(stage.rawValue) · step \(done + 1)/\(total) · region \(regionIndex)/\(regionsTotal)"
            }
            return "\(stage.rawValue) · step \(done + 1)/\(total)"
        case .paused(let reason, let lastStage):
            return "Paused (\(reason.rawValue)) at \(lastStage.rawValue)"
        case .completed(let seconds, let speakerCount):
            return String(format: "Done · %.1fs · %d speaker(s)", seconds, speakerCount)
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
