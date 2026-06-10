import AppKit
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
    @Environment(RefinementJobQueueViewModel.self) private var queueVM
    @Environment(MenuBarSettings.self) private var settings

    /// The recording whose transcript is being viewed in a sheet (#4), if any.
    @State private var viewing: RecordingEntry?

    var body: some View {
        VStack(spacing: 0) {
            if let err = queueVM.lastEnqueueError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange)
            }
            Group {
                if scanner.recordings.isEmpty {
                    emptyState
                } else {
                    List(scanner.recordings) { recording in
                        row(recording)
                    }
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
            VStack(alignment: .leading, spacing: 2) {
                // Title line: name · duration (only when refined, since
                // unrefined entries carry `durationSeconds == 0`) · the
                // refinement status icon. The icon is hover-only — full
                // text moved into `.help()` tooltips to keep the line tight.
                HStack(spacing: 8) {
                    Text(recording.displayTitle)
                        .help(recording.displayName)
                    if recording.isRefined {
                        Text(RecordingEntry.formatDuration(recording.durationSeconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    RefineStatusIcon(recording: recording)
                }
                if recording.isRefined && !recording.speakers.isEmpty {
                    // Pills replace the older "N speakers · Ns" subtitle —
                    // richer info (tinted per kind: You / Unknown #N / named)
                    // wrapped onto multiple rows when there are many.
                    SpeakerPillsView(speakers: recording.speakers)
                }
            }
            Spacer()
            // The one always-visible affordance — a quiet chevron for the
            // primary action. Everything else lives in the context menu.
            Button { viewing = recording } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("View transcript")
                .help("View transcript")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewing = recording }
        .contextMenu {
            Button("View Transcript") { viewing = recording }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.folderURL])
            }
            Divider()
            // "Refine" enqueues into the refinement job queue (E3). Disabled
            // while a job for this recording is already running or queued.
            Button("Refine") {
                Task {
                    await queueVM.enqueueManual(
                        folderURL: recording.folderURL,
                        recordingId: recording.id,
                        refineModelName: settings.refineModelName)
                }
            }
            .disabled(jobInFlight(recording.id))
        }
    }

    /// True when a refinement job for this recording is already running or
    /// waiting in the queue — used to disable the Refine button.
    private func jobInFlight(_ recordingId: String) -> Bool {
        if queueVM.running?.recordingId == recordingId { return true }
        return queueVM.queued.contains { $0.recordingId == recordingId }
    }

}

/// One small icon next to the recording name conveying refinement status
/// (queued, running, refined, failed, not-yet-refined). The full status text
/// moved into a `.help(...)` tooltip — on hover the user sees e.g.
/// "Refining…" or "Not yet refined".
///
/// Queue state wins over the intrinsic refined flag: a recording that
/// completed weeks ago and is now mid-re-refine should show the spinner,
/// not the green check. Recent terminal states (cancelled, or any unknown
/// future case) fall through to the intrinsic state so the icon never
/// disappears — a row without a status indicator looked broken in testing.
private struct RefineStatusIcon: View {
    let recording: RecordingEntry
    @Environment(RefinementJobQueueViewModel.self) private var queueVM

    var body: some View {
        if queueVM.running?.recordingId == recording.id {
            icon("gear", tint: .blue, help: "Refining…")
        } else if queueVM.queued.contains(where: { $0.recordingId == recording.id }) {
            icon("clock", tint: .secondary, help: "Queued for refinement")
        } else if let recent = queueVM.recent.first(where: { $0.recordingId == recording.id }) {
            switch recent.state {
            case .completed:
                icon("checkmark.circle.fill", tint: .green, help: "Refined")
            case .failed:
                icon("exclamationmark.circle.fill", tint: .red,
                     help: "Refinement failed")
            default:
                intrinsic
            }
        } else {
            intrinsic
        }
    }

    @ViewBuilder
    private var intrinsic: some View {
        if recording.isRefined {
            icon("checkmark.circle.fill", tint: .green, help: "Refined")
        } else {
            icon("clock.badge", tint: .orange, help: "Not yet refined")
        }
    }

    private func icon(_ name: String, tint: Color, help: String) -> some View {
        Image(systemName: name)
            .font(.caption)
            .foregroundStyle(tint)
            .help(help)
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
                Text(recording.displayTitle).font(.headline)
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
        let finalURL = recording.finalURL
        let liveURL = recording.liveURL
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
