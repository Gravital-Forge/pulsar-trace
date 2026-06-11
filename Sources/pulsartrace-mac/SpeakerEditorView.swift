import AppKit
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The speaker editor (R44) — list, inline rename, merge/split/delete, undo
/// toast, recently-deleted section. Pure bindings over `SpeakerEditorViewModel`.
///
/// Rendered as a detail pane of `MainWindowView`'s sidebar window (#6). The
/// detail root is a plain `List` and Merge/Split live in the window toolbar,
/// so this pane's window chrome matches the Recordings pane (a `VStack`-rooted
/// detail made macOS draw the split-view corners/sidebar differently).
///
/// The pane is selection-driven (§8): the live-speaker list carries a
/// `Set<String>` multi-selection. ⌘-clicking exactly two speakers enables the
/// toolbar **Merge** (both operands seeded from the selection; the sheet's
/// pickers stay editable — which one to keep is still an explicit choice);
/// exactly one selection enables **Split**. Rename keeps the double-click
/// gesture plus the context menu — no Return-to-rename — and the gesture
/// coexists with `List` selection via a `simultaneousGesture` so the first
/// click still selects.
///
/// The `SpeakerLibrary` actor is opened asynchronously on appear (its init is
/// `async throws`), so this view owns the optional ViewModel and shows a
/// loading state until it resolves — or an error state if the open fails.
struct SpeakerEditorView: View {
    /// The process-wide events writer — wired into the ViewModel so speaker
    /// edits emit `speaker_*` / `final_md_rewritten` events in the shipped app.
    /// Passed explicitly because `EventWriter` is not an `@Observable` the
    /// environment can carry.
    let events: EventWriter

    @Environment(MenuBarSettings.self) private var settings

    @State private var viewModel: SpeakerEditorViewModel?
    /// Set when opening the speaker library fails — shows an error state
    /// instead of an indefinite "Loading…".
    @State private var loadError: String?
    @State private var renameTarget: String?
    @State private var renameText = ""
    /// Multi-selection over the live-speaker rows (§8). ⌘-click two to enable
    /// Merge; a single selection enables Split. Only live rows are tagged, but
    /// the seeding code filters the selection through `liveSpeakers` ids so a
    /// stray deleted/delisted id could never leak into an operand.
    @State private var selection: Set<String> = []
    /// Drives the rename `TextField`'s first-responder state — set on appear so
    /// the cursor visibly lands in the field, paired with a select-all so the
    /// existing name is highlighted and typing replaces it in one keystroke.
    @FocusState private var renameFieldFocused: Bool

    /// The speaker awaiting the delist ("Don't recognize") confirmation —
    /// just the two fields the dialog needs. A full `Speaker` also carries a
    /// 256-float centroid; no reason to park that in view state.
    private struct PendingDelist {
        let id: String
        let name: String
        /// How many recordings the delist would rewrite — fetched from
        /// `appearances(ofSpeaker:)`. Carried here (not as separate state)
        /// so the dialog always shows a consistent (id, name, count) triple
        /// even if two right-clicks race across the await.
        let count: Int
    }

    /// Non-nil while the delist confirmation dialog is up (Task 7a) —
    /// delisting rewrites `final.md` files on disk, so it must be confirmed.
    @State private var pendingDelist: PendingDelist?

    // Merge sheet state.
    @State private var showMerge = false
    @State private var mergePrimaryId: String?
    @State private var mergeOtherId: String?
    /// True while the merge confirmation dialog is up (Task 7b) — merging
    /// rewrites `final.md` files on disk, so it must be confirmed.
    @State private var showMergeConfirm = false
    /// How many recordings the pending merge would rewrite — the merged-away
    /// speaker's appearance count, fetched before presenting the dialog.
    @State private var pendingMergeCount = 0

    // Split sheet state.
    @State private var showSplit = false
    @State private var splitOriginalId: String?
    @State private var splitNewName = ""
    /// Recording ids selected to move to the new speaker (#3 — replaces the
    /// old comma-separated-ids text field).
    @State private var splitSelectedRecordingIds: Set<String> = []

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else if let loadError {
                errorState(loadError)
            } else {
                ProgressView("Loading speaker library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { RecordToolbarButton() }
            // Always present (disabled until usable) so the window toolbar —
            // and thus the chrome — does not change as the library loads.
            ToolbarItemGroup {
                // Busy indicator while a retroactive final.md rewrite is in
                // flight — paired with `.disabled(isRewriting)` on the list.
                // Conditionally present, NOT opacity-hidden: macOS draws
                // button-like chrome around a toolbar item even at opacity 0,
                // leaving a ghost "empty button" next to Merge/Split. The
                // toolbar reflows naturally when this appears.
                if viewModel?.isRewriting == true {
                    ProgressView()
                        .controlSize(.small)
                        .help("Rewriting transcripts…")
                        .accessibilityLabel("Rewriting transcripts")
                }
                // Selection-driven enablement (§8): Merge needs exactly two
                // ⌘-clicked operands, Split exactly one. Counted against the
                // LIVE selection — a merged-away or deleted speaker's id can
                // linger in the raw set and must not keep the buttons armed
                // with operands the user never chose. Still gated on a loaded
                // VM and on no rewrite being in flight.
                Button("Merge…") {
                    if let viewModel { startMerge(viewModel) }
                }
                .disabled(liveSelectionCount != 2
                    || viewModel?.isRewriting == true)
                .help("Merge the two selected speakers")
                Button("Split…") {
                    if let viewModel { startSplit(viewModel) }
                }
                .disabled(liveSelectionCount != 1
                    || viewModel?.isRewriting == true)
                .help("Split a recording's lines out of the selected speaker")
            }
        }
        .task { await loadLibrary() }
        .sheet(isPresented: $showMerge) {
            if let viewModel { mergeSheet(viewModel) }
        }
        .sheet(isPresented: $showSplit) {
            if let viewModel { splitSheet(viewModel) }
        }
    }

    /// How many of the selected ids are LIVE speakers right now. The raw
    /// `selection` set is never pruned by SwiftUI when rows vanish (merge,
    /// delete, delist), so gating must count through `liveSpeakers` — nil VM
    /// counts as zero.
    private var liveSelectionCount: Int {
        guard let viewModel else { return 0 }
        return viewModel.liveSpeakers.count { selection.contains($0.id) }
    }

    @ViewBuilder
    private func content(_ viewModel: SpeakerEditorViewModel) -> some View {
        if viewModel.liveSpeakers.isEmpty
            && viewModel.deletedSpeakers.isEmpty
            && viewModel.delistedSpeakers.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                // Untitled — the pane's navigation title already says
                // "Speakers"; a `Section("Speakers")` header here was a
                // duplicate label.
                Section {
                    ForEach(viewModel.liveSpeakers) { speaker in
                        // Only live rows are tagged for selection — the
                        // Recently Deleted/Delisted rows below stay
                        // unselectable so a stray id can't seed Merge/Split.
                        speakerRow(speaker, viewModel: viewModel)
                            .tag(speaker.id)
                    }
                }
                if !viewModel.deletedSpeakers.isEmpty {
                    Section("Recently Deleted") {
                        ForEach(viewModel.deletedSpeakers) { speaker in
                            HStack {
                                Text(speaker.name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") {
                                    Task { await viewModel.undelete(
                                        speakerId: speaker.id) }
                                }
                            }
                            // ForEach over Identifiable rows gets IMPLICIT
                            // selection tags (Speaker.ID == String matches the
                            // selection set) — opt the tombstones out
                            // explicitly so they can't arm Merge/Split.
                            .selectionDisabled(true)
                        }
                    }
                }
                if !viewModel.delistedSpeakers.isEmpty {
                    Section("Recently Delisted") {
                        ForEach(viewModel.delistedSpeakers) { speaker in
                            HStack {
                                Text(speaker.name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") {
                                    Task { await viewModel.undelist(
                                        speakerId: speaker.id) }
                                }
                                .help("Recognize this speaker again. Their "
                                    + "lines marked 'Unrecognized' are "
                                    + "restored to this name.")
                            }
                            .selectionDisabled(true)
                        }
                    }
                }
            }
            // A rewrite fans out over every affected final.md on disk — the
            // list is disabled while one is in flight so edits cannot stack
            // (the toolbar shows the paired busy indicator). Applied before
            // the insets so the error ✕ and Undo stay clickable.
            .disabled(viewModel.isRewriting)
            // §8: banners move off-content (overlay → safeAreaInset) so they
            // never cover list rows; they carry move+opacity transitions.
            .safeAreaInset(edge: .top, spacing: 0) { errorBanner(viewModel) }
            .safeAreaInset(edge: .bottom, spacing: 0) { undoBanner(viewModel) }
            // §6 planning note: a navigation-away (Record → Recordings, or a
            // sidebar switch) must not silently discard an in-progress rename.
            .onDisappear { commitPendingRename(viewModel) }
            // Task 7a — delisting rewrites every final.md the speaker appears
            // in, so it is confirmed with the impact count fetched when the
            // context-menu item staged `pendingDelist`.
            .confirmationDialog(
                "Stop recognizing \(pendingDelist?.name ?? "")?",
                isPresented: Binding(
                    get: { pendingDelist != nil },
                    set: { if !$0 { pendingDelist = nil } })
            ) {
                Button("Stop Recognizing", role: .destructive) {
                    if let s = pendingDelist {
                        Task { await viewModel.delist(speakerId: s.id) }
                    }
                    pendingDelist = nil
                }
            } message: {
                let count = pendingDelist?.count ?? 0
                Text(count == 0
                     ? "Their lines become “Unrecognized”. Undoable for 30 days."
                     : "\(count) recording\(count == 1 ? "" : "s") will be rewritten. Their lines become “Unrecognized”. Undoable for 30 days.")
            }
        }
    }

    /// A dismissible error banner for a failed edit (`viewModel.lastError`).
    /// Primary text on a red tint (not white-on-red, which failed WCAG
    /// contrast) so it reads in both light and dark appearances.
    private func errorBanner(_ viewModel: SpeakerEditorViewModel) -> some View {
        Group {
            if let error = viewModel.lastError {
                HStack(alignment: .firstTextBaseline) {
                    Text(error)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        viewModel.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss error")
                }
                .foregroundStyle(.primary)
                .padding(8)
                .background(
                    Color.red.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.4)))
                .padding(12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // `lastError` is a `String?` (Equatable), so animate on it directly.
        .animation(.default, value: viewModel.lastError)
    }

    /// The undo affordance shown after a destructive edit (R44).
    private func undoBanner(_ viewModel: SpeakerEditorViewModel) -> some View {
        Group {
            if let toast = viewModel.undoToast {
                HStack {
                    Text(toast.message)
                    Spacer()
                    Button("Undo") {
                        Task {
                            await toast.action()
                            // Clears the toast AND cancels its auto-dismiss
                            // clock (`undoToast` is private(set) on the VM).
                            viewModel.dismissToast()
                        }
                    }
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // `UndoToast` carries a non-Equatable `action` closure, so animate on
        // its presence (Bool) rather than on the value itself.
        .animation(.default, value: viewModel.undoToast != nil)
    }

    /// R44 edge case — no speakers yet.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Record a meeting to get started")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when the speaker library could not be opened (I6).
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Could not open the speaker library")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                loadError = nil
                Task { await loadLibrary() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func speakerRow(
        _ speaker: Speaker, viewModel: SpeakerEditorViewModel
    ) -> some View {
        HStack {
            if renameTarget == speaker.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFieldFocused)
                    .onAppear {
                        renameFieldFocused = true
                        // SwiftUI's TextField has no built-in "select all on
                        // focus": the field editor (`NSText`) is the only
                        // object that can do it, and AppKit doesn't install
                        // the field editor until the focus change has been
                        // processed — hence the async hop after setting
                        // `renameFieldFocused`.
                        DispatchQueue.main.async {
                            (NSApp.keyWindow?.firstResponder as? NSText)?
                                .selectAll(nil)
                        }
                    }
                // Cancel + Save replace the Rename/Delete pair while editing —
                // they make the "you are now editing" state visually obvious
                // (Save is the blue default button) and give the click a
                // discoverable target. Save owns Return (`.defaultAction`) and
                // Cancel owns Escape (`.cancelAction`), so the previous
                // `.onSubmit` / `.onExitCommand` modifiers are no longer needed
                // — having both would double-fire on Return.
                Button("Cancel") { renameTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        await viewModel.rename(
                            speakerId: speaker.id, to: renameText)
                        renameTarget = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                // Double-click renames; everything else is in the context
                // menu. The gesture and menu are scoped to this branch (not
                // the whole row) so they can't fire while the rename
                // TextField is up — a double-click selecting a word inside
                // the field must not reset `renameText`.
                HStack {
                    Text(speaker.name)
                    Spacer()
                }
                .contentShape(Rectangle())
                // `simultaneousGesture` rather than `.onTapGesture(count: 2)`
                // so the List keeps the first click for selection and the
                // second fires rename (§12 coexistence — matches the
                // recordings list).
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    renameText = speaker.name
                    renameTarget = speaker.id
                })
                .contextMenu {
                    Button("Rename") {
                        renameText = speaker.name
                        renameTarget = speaker.id
                    }
                    // "Don't Recognize This Speaker" — hidden for the mic
                    // speaker (name `"You"`), matching the ViewModel's
                    // mic-rejection guard. The library doesn't carry an
                    // `isMicrophone` flag on a `Speaker` today, so the UI
                    // mirrors the same name-based policy. See
                    // SpeakerEditorViewModel.delist for the rationale.
                    // Delisting rewrites final.md files, so this only stages
                    // the confirmation (Task 7a) — the dialog on the List
                    // performs the actual delist.
                    if speaker.name != "You" {
                        Button("Don't Recognize This Speaker") {
                            Task {
                                let count = await viewModel
                                    .appearances(ofSpeaker: speaker.id).count
                                pendingDelist = PendingDelist(
                                    id: speaker.id, name: speaker.name,
                                    count: count)
                            }
                        }
                        .help("Stop recognizing this speaker. Their lines in "
                            + "transcripts become 'Unrecognized'. Undoable for "
                            + "30 days.")
                    }
                    Divider()
                    // One-click + undo toast, no confirmation — locked
                    // decision; delete is a soft tombstone and rewrites
                    // nothing on disk.
                    Button("Delete", role: .destructive) {
                        Task { await viewModel.delete(speakerId: speaker.id) }
                    }
                }
            }
        }
    }

    /// §6 planning note: navigating away (Record button → Recordings, or a
    /// sidebar switch) must not silently discard an in-progress rename —
    /// commit it like Save. Deliberately NOT wired to focus loss: the inline
    /// Cancel/Save buttons blur the field when clicked, and a blur-commit
    /// would turn Cancel into Save.
    private func commitPendingRename(_ viewModel: SpeakerEditorViewModel) {
        guard let id = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty else { return }
        Task { await viewModel.rename(speakerId: id, to: name) }
    }

    // MARK: - Merge

    /// Seed the merge sheet's pickers and present it.
    private func startMerge(_ viewModel: SpeakerEditorViewModel) {
        // Seed both operands from the ⌘-click selection (§8). The sheet's
        // pickers stay editable — which one to keep is still an explicit
        // choice; selection order is not meaningful in a Set, so the seed
        // order follows the list order.
        let selected = viewModel.liveSpeakers.filter { selection.contains($0.id) }
        mergePrimaryId = selected.first?.id ?? viewModel.liveSpeakers.first?.id
        mergeOtherId = selected.dropFirst().first?.id
            ?? viewModel.liveSpeakers.dropFirst().first?.id
        showMerge = true
    }

    @ViewBuilder
    private func mergeSheet(_ viewModel: SpeakerEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Speakers").font(.headline)
            Picker("Keep", selection: $mergePrimaryId) {
                ForEach(viewModel.liveSpeakers) { speaker in
                    Text(speaker.name).tag(speaker.id as String?)
                }
            }
            Picker("Merge away", selection: $mergeOtherId) {
                ForEach(viewModel.liveSpeakers) { speaker in
                    Text(speaker.name).tag(speaker.id as String?)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showMerge = false }
                // Task 7b — merging rewrites every final.md the merged-away
                // speaker appears in, so this only fetches the impact count
                // and raises the confirmation dialog; the dialog's
                // destructive Merge performs the merge and closes the sheet.
                Button("Merge") {
                    if let other = mergeOtherId {
                        Task {
                            pendingMergeCount = await viewModel
                                .appearances(ofSpeaker: other).count
                            showMergeConfirm = true
                        }
                    }
                }
                .disabled(mergePrimaryId == nil || mergeOtherId == nil
                    || mergePrimaryId == mergeOtherId)
            }
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 180)
        .confirmationDialog(
            "Merge ‘\(speakerName(mergeOtherId, in: viewModel))’ into "
                + "‘\(speakerName(mergePrimaryId, in: viewModel))’?",
            isPresented: $showMergeConfirm
        ) {
            Button("Merge", role: .destructive) {
                if let primary = mergePrimaryId,
                   let other = mergeOtherId, primary != other {
                    Task {
                        await viewModel.merge(
                            primaryId: primary, otherId: other)
                    }
                }
                showMerge = false
            }
        } message: {
            Text("\(pendingMergeCount) recording\(pendingMergeCount == 1 ? "" : "s") will be rewritten.")
        }
    }

    /// Resolve a speaker id to its display name from the live list — used by
    /// the merge confirmation's title.
    private func speakerName(
        _ id: String?, in viewModel: SpeakerEditorViewModel
    ) -> String {
        viewModel.liveSpeakers.first { $0.id == id }?.name ?? ""
    }

    // MARK: - Split

    /// Seed the split sheet and present it.
    private func startSplit(_ viewModel: SpeakerEditorViewModel) {
        // Split is a one-operand action — seed from the single selection
        // (§8), falling back to the first live speaker.
        splitOriginalId = viewModel.liveSpeakers
            .first { selection.contains($0.id) }?.id
            ?? viewModel.liveSpeakers.first?.id
        splitNewName = ""
        splitSelectedRecordingIds = []
        showSplit = true
    }

    /// The split sheet (#3) — pick the source speaker, name the new speaker,
    /// and tick the recordings to move. The recording multi-select replaces
    /// the old free-text "comma-separated recording ids" field, which required
    /// the user to know opaque `rec_<short>` ids.
    @ViewBuilder
    private func splitSheet(_ viewModel: SpeakerEditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split Speaker").font(.headline)
            Picker("From", selection: $splitOriginalId) {
                ForEach(viewModel.liveSpeakers) { speaker in
                    Text(speaker.name).tag(speaker.id as String?)
                }
            }
            TextField("New speaker name", text: $splitNewName)

            Text("Recordings to move")
                .font(.caption)
                .foregroundStyle(.secondary)
            SplitRecordingPicker(
                viewModel: viewModel,
                speakerId: splitOriginalId,
                selection: $splitSelectedRecordingIds)
                .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Cancel") { showSplit = false }
                Button("Split") {
                    if let original = splitOriginalId,
                       !splitSelectedRecordingIds.isEmpty {
                        Task {
                            await viewModel.split(
                                originalId: original,
                                movingRecordingIds: Array(splitSelectedRecordingIds),
                                newName: splitNewName)
                        }
                    }
                    showSplit = false
                }
                .disabled(splitOriginalId == nil
                    || splitNewName.trimmingCharacters(in: .whitespaces).isEmpty
                    || splitSelectedRecordingIds.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 320)
    }

    /// Build the ViewModel via its `load` factory — the VM owns opening the
    /// `SpeakerLibrary` at the standard path; this view never constructs
    /// engine objects. A failure surfaces an error state (I6) instead of an
    /// indefinite loading spinner; the rendered error is home-redacted so it
    /// cannot leak `/Users/<name>/...` into the UI.
    private func loadLibrary() async {
        guard viewModel == nil else { return }
        do {
            viewModel = try await SpeakerEditorViewModel.load(
                events: events, settings: settings)
        } catch {
            loadError = PathRedactor.redactHome("\(error)")
        }
    }
}

/// The recording multi-select inside the split sheet (#3).
///
/// Loads the source speaker's appearances whenever the selected speaker
/// changes and renders them as toggleable rows. Lives in its own view so the
/// `.task(id:)`-driven reload is scoped tightly and does not re-run the whole
/// split sheet.
private struct SplitRecordingPicker: View {
    let viewModel: SpeakerEditorViewModel
    /// The source speaker whose recordings can be moved; `nil` until picked.
    let speakerId: String?
    @Binding var selection: Set<String>

    @State private var appearances: [SpeakerAppearance] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appearances.isEmpty {
                Text("This speaker has no recordings to move.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appearances, id: \.recordingId) { appearance in
                    Toggle(
                        appearance.recordingFolderName,
                        isOn: binding(for: appearance.recordingId))
                }
            }
        }
        .task(id: speakerId) { await reload() }
    }

    /// A per-recording toggle binding into the shared `selection` set.
    private func binding(for recordingId: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(recordingId) },
            set: { isOn in
                if isOn { selection.insert(recordingId) }
                else { selection.remove(recordingId) }
            })
    }

    /// Reload appearances for the current speaker. Clears the selection so a
    /// recording from a previously-picked speaker cannot leak into the split.
    private func reload() async {
        loaded = false
        selection = []
        guard let speakerId else {
            appearances = []
            loaded = true
            return
        }
        appearances = await viewModel.appearances(ofSpeaker: speakerId)
        loaded = true
    }
}
