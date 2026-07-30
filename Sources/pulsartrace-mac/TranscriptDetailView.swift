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

    /// Shared app environment — the single speaker library + events writer the
    /// owner-reassignment view model is built over (PT-P8-R6). Optional so the
    /// previews/tests that construct this view without an environment still
    /// render (the owner controls just stay hidden).
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    @State private var autoScroll = AutoScrollController()
    @State private var find = TranscriptFindActivator()
    /// The owner-reassignment view model (PT-P8-R6), built lazily from the
    /// shared environment when a mic-diarized recording is shown.
    @State private var ownerVM: SpeakerEditorViewModel?

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
            diarizeMicControl(row)
            ownerReassignmentControls(row)
        }
        .padding(12)
        // Build the owner-reassignment VM once the environment is available
        // (PT-P8-R6). Built once, shared across recordings — the VM is
        // recording-agnostic (recording ids are passed per action, and the
        // sidecar gate reads the shown folder on each render).
        .task(id: detailModel.shown?.id) { await buildOwnerVM() }
    }

    // MARK: Per-recording mic-diarization stamp (PT-P8-R8)

    /// The per-recording "Diarize microphone" checkbox. Reflects the recording's
    /// `options.json` stamp (`diarizeMicStamp`); toggling writes the sidecar and
    /// rescans so the row/detail pick up the change. The post-hoc flow is
    /// checkbox → Refine (the Refine affordance is unchanged). Disabled for a
    /// live recording — the engine never re-reads the sidecar mid-recording.
    @ViewBuilder
    private func diarizeMicControl(_ row: RecordingRow) -> some View {
        Toggle("Diarize microphone", isOn: Binding(
            get: { row.entry.diarizeMicStamp },
            set: { newValue in
                // Mirror the rename flow's write-then-refresh, owned by the
                // pane model (which holds the scanner). Without an environment
                // (previews) there is nothing to refresh; do nothing.
                guard let environment else { return }
                Task {
                    await environment.paneModel.setDiarizeMic(
                        recordingId: row.entry.id, enabled: newValue)
                }
            }))
            .toggleStyle(.checkbox)
            .disabled(row.isLive)
            .font(.caption)
            .accessibilityIdentifier(A11yID.Recordings.diarizeMicCheckbox)
            .help("Applies on the next refine. Tick, then click Refine, to "
                + "split in-person speakers on your microphone — untick and "
                + "refine to undo.")
    }

    // MARK: Owner reassignment ("This is me" / "Not me", PT-P8-R6)

    /// The owner-reassignment affordances, shown only for a mic-diarized
    /// recording (its `mic-diarization.json` exists): "Not me" on the `You` mic
    /// row, "This is me" on each mic-channel guest row (`isMicrophone` +
    /// `speakerId != nil`). Earlier recordings — no sidecar — show nothing.
    @ViewBuilder
    private func ownerReassignmentControls(_ row: RecordingRow) -> some View {
        if let ownerVM, ownerVM.canReassignOwner(folderURL: row.entry.folderURL) {
            let micGuests = row.entry.speakers.filter {
                $0.isMicrophone && $0.speakerId != nil
            }
            let hasOwner = row.entry.speakers.contains {
                $0.isMicrophone && $0.label == SpeakerEditService.microphoneSpeakerName
            }
            if hasOwner || !micGuests.isEmpty {
                HStack(spacing: 8) {
                    if hasOwner {
                        Button("Not me") {
                            Task { await ownerVM.demoteOwner(recordingId: row.entry.id) }
                        }
                        .accessibilityIdentifier(A11yID.SpeakerEditor.notMe)
                        .help("This mic speaker isn't you — demote it to a "
                            + "regular speaker.")
                    }
                    ForEach(micGuests) { guest in
                        Button("This is me") {
                            guard let speakerId = guest.speakerId else { return }
                            Task {
                                await ownerVM.designateOwner(
                                    recordingId: row.entry.id, speakerId: speakerId)
                            }
                        }
                        .accessibilityIdentifier(A11yID.SpeakerEditor.thisIsMe)
                        .help("Attribute “\(guest.label)” on the mic channel to you.")
                    }
                }
                .font(.caption)
                .disabled(ownerVM.isRewriting)
            }
        }
    }

    /// Build the owner-reassignment VM from the shared environment (the single
    /// speaker-library writer + events + owner profile). No-op without an
    /// environment (previews) or before the library opens.
    private func buildOwnerVM() async {
        guard ownerVM == nil, let environment,
              let library = await environment.sharedSpeakerLibrary()
        else { return }
        ownerVM = await SpeakerEditorViewModel.using(
            library: library, events: environment.events, settings: settings,
            ownerProfile: environment.ownerProfileStore())
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
