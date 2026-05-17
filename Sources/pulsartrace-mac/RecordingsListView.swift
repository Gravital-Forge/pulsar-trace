import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// The recordings list (R31) — past recordings with re-refine and
/// reveal-in-Finder. Pure bindings over `RecordingsScanner`.
struct RecordingsListView: View {
    @Environment(RecordingsScanner.self) private var scanner
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                if scanner.isScanning { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }
            }
            .padding(12)

            Divider()

            if scanner.recordings.isEmpty {
                emptyState
            } else {
                List(scanner.recordings) { recording in
                    row(recording)
                }
            }
        }
        .frame(width: 460, height: 360)
        .task { await scanner.refresh() }
    }

    /// R31 edge case — no recordings yet.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Record a meeting to get started")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ recording: RecordingEntry) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(recording.displayName)
                Text("\(recording.speakers.count) speaker(s) · "
                    + "\(Int(recording.durationSeconds))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.folderURL])
            }
            Button("Re-refine") {
                Task { await scanner.reRefine(recording) }
            }
            .disabled(scanner.isScanning)
        }
    }
}
