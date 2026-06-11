import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// The Recordings pane (§4): master list + transcript detail in a resizable,
/// persistent split. Reads models from the SwiftUI environment and hands
/// them to the panes by init (they cross an NSHostingView boundary inside
/// `PersistentHSplit` — environment does not flow across it).
struct RecordingsSplitView: View {
    @Environment(RecordingsPaneModel.self) private var paneModel
    @Environment(TranscriptDetailModel.self) private var detailModel
    @Environment(RefinementJobQueueViewModel.self) private var queueVM
    @Environment(MenuBarSettings.self) private var settings
    @Environment(RecordingViewModel.self) private var recording
    @Environment(AppNavigation.self) private var navigation
    @Environment(RecordingsScanner.self) private var scanner

    var body: some View {
        PersistentHSplit(
            // "4" suffix: the autosave key is bumped whenever the default
            // proportions change (40–60 since QA round 4; 50–50 and 1/3
            // before), so the new default applies even where an old key
            // already had a saved position.
            autosaveName: "RecordingsSplit4",
            defaultFraction: 0.4,
            leadingMinWidth: 240,
            trailingMinWidth: 320,
            leading: RecordingsListPane(
                paneModel: paneModel, queueVM: queueVM,
                settings: settings, navigation: navigation,
                recording: recording),
            trailing: TranscriptDetailView(
                detailModel: detailModel, queueVM: queueVM, settings: settings))
        .toolbar {
            ToolbarItem(placement: .navigation) { RecordToolbarButton() }
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
        .safeAreaInset(edge: .top, spacing: 0) { recordingStateBanner }
        .task { await scanner.refresh() }
        .onAppear {
            paneModel.ensureSelection()
            syncDetail()
        }
        .onChange(of: navigation.selectedRecordingID) { syncDetail() }
        // Load-bearing: this onChange is the SOLE refresher of
        // `detailModel.shown` (the one snapshot in the system). The eager
        // `paneModel.rows` read also registers scanner/recording/queue state
        // as body dependencies. O(rows) per evaluation — fine at a personal
        // library's scale.
        .onChange(of: paneModel.rows) {
            paneModel.ensureSelection()
            syncDetail()
        }
        .onChange(of: recording.status.isActive) {
            // A recording just started or ended. On stop/crash the live row
            // vanishes and the folder only surfaces via a scan — refresh so
            // the recording doesn't blink out of the list (§10).
            Task { await scanner.refresh() }
        }
        .animation(.default, value: bannerKind)
    }

    /// Push the selected row (fresh snapshot) into the detail model.
    private func syncDetail() {
        let row = paneModel.rows.first { $0.id == navigation.selectedRecordingID }
        detailModel.show(row)
    }

    /// Stable discriminator for banner animations.
    private var bannerKind: Int {
        switch recording.status {
        case .crashed: return 1
        case .error: return 2
        default: return 0
        }
    }

    /// Crash/error parity with the menubar (§6): the window must be
    /// self-sufficient.
    @ViewBuilder
    private var recordingStateBanner: some View {
        switch recording.status {
        case .crashed:
            HStack(spacing: 8) {
                Text("Recording stopped unexpectedly.")
                Spacer()
                Button("Recover Transcript") {
                    Task { await recording.recoverFromCrash() }
                }
                Button("Dismiss") { recording.dismissCrash() }
            }
            .font(.callout)
            .padding(10)
            .background(.red.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        case .error(let message):
            HStack(spacing: 8) {
                Text(message)
                Spacer()
                Button("Dismiss") { recording.dismissCrash() }
            }
            .font(.callout)
            .padding(10)
            .background(.red.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        default:
            EmptyView()
        }
    }
}

/// Left side of the split: filter field + day-grouped, selection-driven list.
private struct RecordingsListPane: View {
    @Bindable var paneModel: RecordingsPaneModel
    let queueVM: RefinementJobQueueViewModel
    let settings: MenuBarSettings
    let navigation: AppNavigation
    let recording: RecordingViewModel

    @State private var renameTargetID: String?
    @State private var renameText = ""
    /// Per-row focus (not a Bool): the blur-commit must know WHICH row's
    /// field lost focus, so a re-target (open B while A is editing) can't
    /// be mistaken for a click-away from B.
    @FocusState private var focusedRenameID: String?

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter by title, speaker, or date", text: $paneModel.filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(8)
            Divider()
            content
        }
        .safeAreaInset(edge: .top, spacing: 0) { errorBanners }
        .onDisappear { commitPendingRename() }
        // Clicking away from the rename field commits like Save — losing
        // focus must not strand an open field or discard the edit (§6).
        // Commit only when the row LOSING focus is still the rename target:
        // Escape/Return clear `renameTargetID` first (no-op here), and a
        // re-target flips it to the new row before the old field resigns —
        // committing then would close the new editor before it ever opened.
        .onChange(of: focusedRenameID) { oldValue, _ in
            if oldValue == renameTargetID { commitPendingRename() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if paneModel.rows.isEmpty {
            ContentUnavailableView {
                Label("No Recordings", systemImage: "waveform")
            } description: {
                Text("Record a meeting and its transcript will appear here.")
            } actions: {
                // This pane is BELOW the NSHostingView boundary, so the
                // window's @Environment objects do not flow here — re-inject
                // the two the button needs (the PersistentHSplit pattern).
                RecordToolbarButton()
                    .environment(recording)
                    .environment(navigation)
            }
        } else if paneModel.groups.isEmpty {
            ContentUnavailableView.search(text: paneModel.filterText)
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: selectionBinding) {
            ForEach(paneModel.groups) { group in
                Section(group.key.title) {
                    ForEach(group.rows) { row in
                        rowView(row)
                            .tag(row.id)
                            .contextMenu { contextMenu(row) }
                    }
                }
            }
        }
        .onDeleteCommand {
            guard let id = navigation.selectedRecordingID else { return }
            Task { await paneModel.moveToTrash(recordingId: id) }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { navigation.selectedRecordingID },
            set: { paneModel.select($0) })
    }

    // MARK: Row

    @ViewBuilder
    private func rowView(_ row: RecordingRow) -> some View {
        if renameTargetID == row.id {
            renameField(row)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 2) {
                        titleLine(row)
                            .help(row.entry.displayName)
                        if let caption = row.captionText {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // One solid hit target — without this the gesture only
                    // hit-tests the text glyphs, so the gap between title
                    // and caption would fall through to select-only.
                    .contentShape(Rectangle())
                    // Double-click-to-rename is scoped to the title/caption
                    // text only — double-clicking blank row space, pills, or
                    // the badge selects without opening the editor.
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        beginRename(row)
                    })
                    if row.entry.isRefined && !row.entry.speakers.isEmpty {
                        SpeakerPillsView(speakers: row.entry.speakers)
                    }
                }
                Spacer()
                RecordingBadgeView(badge: row.badge)
            }
            .contentShape(Rectangle())
            // Explicit single-click selection. The row content is an
            // NSHostingView inside the List's NSTableView; once SwiftUI
            // content carries a gesture at the click point, the hosting view
            // consumes the mouseDown and the table's native row selection
            // fires only intermittently. Selecting from our own tap makes
            // every click open the row regardless of who wins that race
            // (keyboard/native selection still flows through the binding).
            .simultaneousGesture(TapGesture().onEnded {
                paneModel.select(row.id)
            })
        }
    }

    /// Title with the unnamed-row duration de-emphasized (smaller +
    /// secondary) so "7:10 AM · 50:11" doesn't read as one title.
    private func titleLine(_ row: RecordingRow) -> Text {
        guard let duration = row.titleDurationText else {
            return Text(row.titleText)
        }
        return Text(row.titleText)
            + Text(" · \(duration)")
                .font(.callout)
                .foregroundStyle(.secondary)
    }

    private func renameField(_ row: RecordingRow) -> some View {
        TextField("Title", text: $renameText)
            .textFieldStyle(.roundedBorder)
            .focused($focusedRenameID, equals: row.id)
            .onAppear {
                focusedRenameID = row.id
                // Select-all needs the AppKit field editor, installed only
                // after the focus change processes (same pattern as the
                // speakers list).
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                }
            }
            .onSubmit { commitRename(row) }
            .onExitCommand { renameTargetID = nil }
    }

    private func beginRename(_ row: RecordingRow) {
        commitPendingRename()   // re-targeting must not silently discard a pending edit
        renameText = row.entry.customTitle ?? ""
        renameTargetID = row.id
    }

    private func commitRename(_ row: RecordingRow) {
        let title = renameText
        renameTargetID = nil
        Task { await paneModel.rename(recordingId: row.id, to: title) }
    }

    /// Navigating away (e.g. the Record button jumping to Recordings, or a
    /// sidebar switch) must not silently discard an in-progress rename —
    /// commit it (§6 planning note).
    private func commitPendingRename() {
        guard let id = renameTargetID,
              let row = paneModel.rows.first(where: { $0.id == id }) else { return }
        commitRename(row)
    }

    // MARK: Context menu (§4.1)

    @ViewBuilder
    private func contextMenu(_ row: RecordingRow) -> some View {
        Button("View Transcript") { paneModel.select(row.id) }
        Button("Rename") { beginRename(row) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([row.entry.folderURL])
        }
        Divider()
        Button("Refine") {
            Task {
                await queueVM.enqueueManual(
                    folderURL: row.entry.folderURL,
                    recordingId: row.id,
                    refineModelName: settings.refineModelName)
            }
        }
        .disabled(jobInFlight(row.id) || row.isLive)
        if case .queued = row.badge {
            Button("Cancel Refinement") {
                Task { await queueVM.cancel(recordingId: row.id) }
            }
        }
        if case .failed(_, _, let retryable) = row.badge, retryable {
            Button("Retry") {
                Task {
                    await queueVM.enqueueManual(
                        folderURL: row.entry.folderURL,
                        recordingId: row.id,
                        refineModelName: settings.refineModelName)
                }
            }
        }
        Divider()
        Button("Move to Trash") {
            Task { await paneModel.moveToTrash(recordingId: row.id) }
        }
        .disabled(row.isLive)
    }

    private func jobInFlight(_ recordingId: String) -> Bool {
        queueVM.running?.recordingId == recordingId
            || queueVM.queued.contains { $0.recordingId == recordingId }
    }

    // MARK: Banners

    @ViewBuilder
    private var errorBanners: some View {
        VStack(spacing: 4) {
            if let err = paneModel.lastActionError {
                dismissibleBanner(err, tint: .red) { paneModel.clearActionError() }
            }
            if let err = queueVM.lastEnqueueError {
                dismissibleBanner(err, tint: .orange) { queueVM.clearEnqueueError() }
            }
        }
        .animation(.default, value: paneModel.lastActionError)
        .animation(.default, value: queueVM.lastEnqueueError)
    }

    private func dismissibleBanner(
        _ text: String, tint: Color, dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss error")
        }
        .padding(8)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.4)))
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Exceptional-only row badge (§4.1).
private struct RecordingBadgeView: View {
    let badge: RecordingRow.Badge

    /// `.increased` while this row is selected and emphasized (accent
    /// selection fill). Emphasized row content is re-rendered against that
    /// fill, where explicitly-tinted symbols wash out to invisible (QA
    /// round 5: the badge "disappeared" on the highlighted row), so every
    /// tint collapses to the semantic selection foreground there — the
    /// system resolves `.primary` to the correct on-selection color.
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var onSelectionFill: Bool { backgroundProminence == .increased }

    private func tint(_ color: Color) -> Color {
        onSelectionFill ? .primary : color
    }

    var body: some View {
        switch badge {
        case .recordingNow(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(tint(.red))
                        .symbolEffect(.pulse)
                    Text(elapsedTimeString(from: startedAt, to: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tint(.red))
                }
            }
            .help("Recording now")
            .accessibilityLabel("Recording now")
        case .queued:
            icon("clock", tint: .secondary, help: "Queued for refinement")
        case .refining(let fraction, let stageName):
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                        .controlSize(.mini)
                        .frame(width: 40)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            // Accent-on-accent is invisible on the selected row.
            .tint(onSelectionFill ? Color.primary : nil)
            .help(stageName.isEmpty ? "Refining…" : "Refining · \(stageName)")
            .accessibilityLabel("Refining")
        case .failed(let friendlyMessage, let errorClass, _):
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(tint(.red))
                .help("\(friendlyMessage) (\(errorClass))")
                .accessibilityLabel("Refinement failed — \(friendlyMessage)")
        case .notYetRefined:
            icon("clock.badge", tint: .orange, help: "Not yet refined")
        case .justRefined:
            icon("checkmark.circle.fill", tint: .green, help: "Just refined")
        case .none:
            EmptyView()
        }
    }

    private func icon(_ name: String, tint: Color, help: String) -> some View {
        Image(systemName: name)
            .font(.caption)
            .foregroundStyle(self.tint(tint))
            .help(help)
            .accessibilityLabel(help)
    }
}
