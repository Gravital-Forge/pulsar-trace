import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// The recordings list (R31) — past recordings with re-refine and
/// reveal-in-Finder. Pure bindings over `RecordingsScanner`.
struct RecordingsListView: View {
    @Environment(RecordingsScanner.self) private var scanner
    /// Invoked by the "Back" button — inline navigation in `MenuBarMenuView`
    /// (FIX 2). Replaces `@Environment(\.dismiss)`, which was unreliable for a
    /// sheet on a `MenuBarExtra` panel.
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { onClose() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                Text("Recordings").font(.headline)
                Spacer()
                if scanner.isScanning { ProgressView().controlSize(.small) }
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
                if recording.isRefined {
                    Text("\(recording.speakers.count) speaker(s) · "
                        + "\(Int(recording.durationSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // FIX 3 — a just-recorded / failed-to-refine folder: no
                    // metadata.json yet. Show the state explicitly.
                    Label("Not yet refined", systemImage: "clock.badge")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.folderURL])
            }
            // "Refine" for both states — running it again on a refined
            // recording simply re-refines it (the "not yet refined" label
            // already conveys which is which).
            Button("Refine") {
                Task { await scanner.reRefine(recording) }
            }
            .disabled(scanner.isScanning)
        }
    }
}
