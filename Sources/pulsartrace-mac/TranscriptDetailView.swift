import AppKit
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// Right side of the Recordings split (§4.2): header + state banner + the
/// shared transcript renderer. Pure binding onto `TranscriptDetailModel`.
struct TranscriptDetailView: View {
    let detailModel: TranscriptDetailModel
    let queueVM: RefinementJobQueueViewModel
    let settings: MenuBarSettings

    @State private var autoScroll = AutoScrollController()
    @State private var find = TranscriptFindActivator()

    var body: some View {
        if let row = detailModel.shown {
            VStack(alignment: .leading, spacing: 0) {
                header(row)
                Divider()
                banner(row)
                transcript(row)
            }
        } else {
            ContentUnavailableView(
                "Select a recording",
                systemImage: "waveform",
                description: Text("Choose a recording from the list to read its transcript."))
        }
    }

    // MARK: Header (§4.2)

    private func header(_ row: RecordingRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entry.displayTitle)
                        .font(.headline)
                        .help(row.entry.displayName)
                    HStack(spacing: 6) {
                        if row.entry.customTitle != nil {
                            Text(row.entry.defaultTitle)
                        }
                        if row.entry.durationSeconds > 0 {
                            Text(RecordingEntry.formatDuration(row.entry.durationSeconds))
                        }
                        if row.isLive {
                            LiveElapsedBadge(startedAt: liveStartedAt(row))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    find.showFind()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(currentLines(row).isEmpty)
                .help("Find in transcript (⌘F)")
                Button {
                    copyTranscriptToPasteboard(currentLines(row))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(currentLines(row).isEmpty)
                .help("Copy the transcript text")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([row.entry.folderURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal the recording folder in Finder")
            }
            if !row.entry.speakers.isEmpty {
                SpeakerPillsView(speakers: row.entry.speakers)
            }
        }
        .padding(12)
    }

    private func liveStartedAt(_ row: RecordingRow) -> Date {
        if case .recordingNow(let startedAt) = row.badge { return startedAt }
        return row.entry.recordingStart
    }

    private func currentLines(_ row: RecordingRow) -> [String] {
        if row.isLive { return detailModel.liveWatcher.lines }
        if case .lines(let lines) = detailModel.content { return lines }
        return []
    }

    // MARK: Banner (§4.2 decision table)

    @ViewBuilder
    private func banner(_ row: RecordingRow) -> some View {
        switch detailModel.banner {
        case .none:
            EmptyView()
        case .queued:
            bannerStrip(tint: .secondary) {
                Text("Queued for refinement")
                Spacer()
                Button("Cancel") {
                    Task { await queueVM.cancel(recordingId: row.id) }
                }
            }
        case .refining(let fraction, let stageName):
            bannerStrip(tint: .blue) {
                if let fraction {
                    ProgressView(value: fraction).controlSize(.small).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(stageName.isEmpty ? "Refining…" : "Refining · \(stageName)")
                Spacer()
                Button("Cancel") {
                    Task { await queueVM.cancel(recordingId: row.id) }
                }
            }
        case .refineCompleted:
            bannerStrip(tint: .green) {
                Text("Refinement complete")
                Spacer()
                Button("Show refined transcript") {
                    detailModel.showRefinedTranscript()
                }
            }
        case .unrefined:
            bannerStrip(tint: .orange) {
                Text("This transcript hasn't been refined yet")
                Spacer()
                Button("Refine") {
                    Task {
                        await queueVM.enqueueManual(
                            folderURL: row.entry.folderURL,
                            recordingId: row.id,
                            refineModelName: settings.refineModelName)
                    }
                }
            }
        case .failed(let friendlyMessage, let errorClass, let retryable):
            bannerStrip(tint: .red) {
                Text("Refinement failed — \(friendlyMessage)").help(errorClass)
                Spacer()
                if retryable {
                    Button("Retry") {
                        Task {
                            await queueVM.enqueueManual(
                                folderURL: row.entry.folderURL,
                                recordingId: row.id,
                                refineModelName: settings.refineModelName)
                        }
                    }
                }
            }
        case .loadError:
            bannerStrip(tint: .red) {
                Text("Could not read the transcript file.")
                Spacer()
                Button("Retry") { detailModel.reload() }
            }
        }
    }

    private func bannerStrip(
        tint: Color, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 8, content: content)
            .font(.caption)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.12))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(tint.opacity(0.3)),
                     alignment: .bottom)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Transcript body

    @ViewBuilder
    private func transcript(_ row: RecordingRow) -> some View {
        Group {
            if row.isLive {
                TranscriptView(
                    lines: detailModel.liveWatcher.lines,
                    placeholder: "Waiting for transcript…",
                    autoScroll: autoScroll,
                    findActivator: find)
            } else {
                switch detailModel.content {
                case .lines(let lines):
                    TranscriptView(lines: lines, findActivator: find)
                case .placeholder:
                    TranscriptView(lines: [], placeholder: "No transcript file yet.")
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unreadable, .empty, .live:
                    // unreadable → the banner carries the error + Retry;
                    // keep the body quiet.
                    Color.clear
                }
            }
        }
        .animation(.default, value: detailModel.banner)
    }
}

/// Ticking elapsed-time badge for the live row's header (red, 1 s cadence).
struct LiveElapsedBadge: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Label(
                elapsedTimeString(from: startedAt, to: context.date),
                systemImage: "circle.fill")
            .foregroundStyle(.red)
            // Stable label for VoiceOver — the ticking time is the value.
            .accessibilityLabel("Recording in progress")
            .accessibilityValue(elapsedTimeString(from: startedAt, to: context.date))
        }
    }
}

/// Shared M:SS / H:MM:SS elapsed formatter (menubar label, record button,
/// live badges).
func elapsedTimeString(from start: Date, to now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}
