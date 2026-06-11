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
            autosaveName: "RecordingsSplit",
            leadingMinWidth: 240,
            trailingMinWidth: 320,
            leading: RecordingsListPane(
                paneModel: paneModel, queueVM: queueVM,
                settings: settings, navigation: navigation),
            trailing: TranscriptDetailView(
                detailModel: detailModel, queueVM: queueVM, settings: settings))
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
        .safeAreaInset(edge: .top, spacing: 0) { recordingStateBanner }
        .task { await scanner.refresh() }
        .onAppear {
            paneModel.ensureSelection()
            syncDetail()
        }
        .onChange(of: navigation.selectedRecordingID) { syncDetail() }
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

    @State private var renameTargetID: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

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
    }

    @ViewBuilder
    private var content: some View {
        if paneModel.rows.isEmpty {
            // Record CTA added with RecordToolbarButton (next task).
            ContentUnavailableView {
                Label("No Recordings", systemImage: "waveform")
            } description: {
                Text("Record a meeting and its transcript will appear here.")
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
                    Text(row.titleText)
                        .help(row.entry.displayName)
                    if let caption = row.captionText {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if row.entry.isRefined && !row.entry.speakers.isEmpty {
                        SpeakerPillsView(speakers: row.entry.speakers)
                    }
                }
                Spacer()
                RecordingBadgeView(badge: row.badge)
            }
            .contentShape(Rectangle())
            // Double-click renames. `simultaneousGesture` (not
            // `onTapGesture`) so the List still receives the first click for
            // selection — the §12 coexistence requirement: neither the
            // gesture nor selection may be dropped.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                beginRename(row)
            })
        }
    }

    private func renameField(_ row: RecordingRow) -> some View {
        TextField("Title", text: $renameText)
            .textFieldStyle(.roundedBorder)
            .focused($renameFocused)
            .onAppear {
                renameFocused = true
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

    var body: some View {
        switch badge {
        case .recordingNow(let startedAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    Text(elapsedTimeString(from: startedAt, to: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
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
            .help(stageName.isEmpty ? "Refining…" : "Refining · \(stageName)")
            .accessibilityLabel("Refining")
        case .failed(let friendlyMessage, let errorClass, _):
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
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
            .foregroundStyle(tint)
            .help(help)
            .accessibilityLabel(help)
    }
}
