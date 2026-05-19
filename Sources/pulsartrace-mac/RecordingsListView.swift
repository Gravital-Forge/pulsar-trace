import AppKit
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The recordings list (R31) — past recordings with view-transcript,
/// re-refine, and reveal-in-Finder. Pure bindings over `RecordingsScanner`.
///
/// Rendered as a detail pane of `MainWindowView`'s sidebar window (#6); the
/// pane title and chrome are owned by the window, so this view is just the
/// list plus a toolbar refresh action.
struct RecordingsListView: View {
    @Environment(RecordingsScanner.self) private var scanner

    /// The recording whose transcript is being viewed in a sheet (#4), if any.
    @State private var viewing: RecordingEntry?

    var body: some View {
        Group {
            if scanner.recordings.isEmpty {
                emptyState
            } else {
                List(scanner.recordings) { recording in
                    row(recording)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await scanner.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)
                .help("Refresh the recordings list")
            }
        }
        .task { await scanner.refresh() }
        .sheet(item: $viewing) { recording in
            RecordedTranscriptSheet(recording: recording) { viewing = nil }
        }
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
            Button("View") { viewing = recording }
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

/// A sheet showing one recording's transcript (#4).
///
/// Reads `final.md` if the recording has been refined, otherwise the
/// provisional `live.md` — both are plain Markdown read once into lines and
/// rendered by the shared `TranscriptView`.
struct RecordedTranscriptSheet: View {
    let recording: RecordingEntry
    var onClose: () -> Void

    @State private var lines: [String] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(recording.displayName).font(.headline)
                Spacer()
                Button {
                    copyTranscriptToPasteboard(lines)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(lines.isEmpty)
                Button("Done") { onClose() }
            }
            .padding(12)
            Divider()

            TranscriptView(
                lines: lines,
                placeholder: loaded
                    ? "This recording has no transcript yet."
                    : "Loading…")
        }
        .frame(width: 540, height: 480)
        .task { await load() }
    }

    /// Read the recording's transcript file into lines, off the main actor.
    ///
    /// Prefers `final.md` (refined, the source of truth); falls back to
    /// `live.md`. Read-only — the transcript files are never modified here.
    /// The read runs on a detached task: `live.md` can be megabytes mid
    /// recording and `String(contentsOf:)` blocks until the whole file loads.
    ///
    /// The result distinguishes three cases: lines on success, an empty array
    /// when no transcript file exists yet (placeholder shown), and `nil` when
    /// a file exists but could not be read (an explicit error line shown).
    private func load() async {
        let finalURL = recording.folderURL.appendingPathComponent(
            RecordingFolder.FileName.final)
        let liveURL = recording.folderURL.appendingPathComponent(
            RecordingFolder.FileName.live)
        let result: [String]? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let url = fm.fileExists(atPath: finalURL.path) ? finalURL : liveURL
            guard fm.fileExists(atPath: url.path) else { return [] }
            guard let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return text.components(separatedBy: "\n")
        }.value
        lines = result ?? ["[Could not read the transcript file.]"]
        loaded = true
    }
}
