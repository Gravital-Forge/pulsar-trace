import AppKit
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The speaker editor (PT-R44) — list, inline rename, merge/split/delete, undo
/// toast, recently-deleted section. Pure bindings over `SpeakerEditorViewModel`.
///
/// Rendered as a detail pane of `MainWindowView`'s sidebar window (#6). The
/// detail root is a plain `List`, so this pane's window chrome matches the
/// Recordings pane (a `VStack`-rooted detail made macOS draw the split-view
/// corners/sidebar differently).
///
/// Every edit acts on the row it was invoked from — never on the list
/// selection. Double-click renames; the context menu carries the rest:
/// **Merge With ▸ \<speaker\>** folds the chosen speaker into the
/// right-clicked one (confirmed with the rewrite impact count), and
/// **Split…** opens the split sheet for the right-clicked speaker. The old
/// toolbar Merge/Split buttons armed by ⌘-click multi-selection are gone —
/// QA showed the arming was undiscoverable and the operand-picker sheet
/// redundant once two speakers were already selected. Selection is therefore
/// single-row and purely visual/keyboard-navigational. Mouse selection is
/// driven by an explicit tap gesture on the row content, not by the table's
/// native click handling — see the comment at the gesture.
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

    /// The app environment — read for the single shared `SpeakerLibrary` writer
    /// (PT-P6-D1), so the editor and the MCP server never open two libraries.
    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel: SpeakerEditorViewModel?
    /// Set when opening the speaker library fails — shows an error state
    /// instead of an indefinite "Loading…".
    @State private var loadError: String?
    @State private var renameTarget: String?
    @State private var renameText = ""
    /// Single visual selection over the live-speaker rows. Purely
    /// navigational — every edit (rename, merge, split, delete, delist) acts
    /// on the row it was invoked from, never on this. Tombstone rows are
    /// selection-disabled.
    @State private var selection: String?
    /// Drives the rename `TextField`'s first-responder state — set on appear so
    /// the cursor visibly lands in the field, paired with a select-all so the
    /// existing name is highlighted and typing replaces it in one keystroke.
    /// Per-row (not a Bool) so the blur-commit knows WHICH row's field lost
    /// focus — a re-target must not read as a click-away from the new row.
    @FocusState private var focusedRenameID: String?

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

    /// The merge awaiting confirmation (Task 7b) — merging rewrites
    /// `final.md` files on disk, so it must be confirmed. Staged by the
    /// context menu's "Merge With ▸ \<speaker\>" with the impact count
    /// already fetched, so the dialog always shows a consistent
    /// (operands, count) tuple.
    private struct PendingMerge {
        /// The right-clicked speaker — survives the merge.
        let primaryId: String
        let primaryName: String
        /// The speaker chosen from the submenu — folded into `primary`.
        let otherId: String
        let otherName: String
        /// How many recordings the merge would rewrite — the merged-away
        /// speaker's appearance count.
        let count: Int
    }

    /// Non-nil while the merge confirmation dialog is up.
    @State private var pendingMerge: PendingMerge?

    // Split sheet state.
    /// The speaker being split — non-nil presents the sheet. An item-driven
    /// sheet (not `isPresented` + a separate id), so the sheet body can never
    /// render against a stale operand: the old `showSplit`/`splitOriginalId`
    /// pair could present before the id write was visible, leaving the sheet
    /// loading appearances for `nil` and showing "no recordings to move" for
    /// a speaker with meetings (QA round 3). The merge sheet had the same
    /// pathology — its operand pickers rendered with nil selections and the
    /// confirm button permanently disabled — which is part of why merge is
    /// now a context-menu + confirmation flow with no sheet at all.
    @State private var splitTarget: Speaker?
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
            ToolbarItemGroup {
                // Busy indicator while a retroactive final.md rewrite is in
                // flight — paired with `.disabled(isRewriting)` on the list.
                // Conditionally present, NOT opacity-hidden: macOS draws
                // button-like chrome around a toolbar item even at opacity 0,
                // leaving a ghost "empty button" in the toolbar. The toolbar
                // reflows naturally when this appears.
                if viewModel?.isRewriting == true {
                    ProgressView()
                        .controlSize(.small)
                        .help("Rewriting transcripts…")
                        .accessibilityLabel("Rewriting transcripts")
                }
            }
        }
        .task { await loadLibrary() }
        // Reload every time the pane appears — on navigation back to Speakers
        // and on window reopen (the `Window` scene keeps this view's `@State`,
        // so the one-shot `.task` build does not re-read). A speaker minted by
        // refinement (an `Unknown #N`) thus shows without navigating away and
        // back. Cheap on a small local DB; `reload()` no-ops while `viewModel`
        // is still nil (the `.task` build owns the first load).
        .onAppear { Task { await viewModel?.reload() } }
        // Item-driven (see `splitTarget`): the sheet receives the speaker
        // value directly, so it cannot present against a stale operand.
        .sheet(item: $splitTarget) { target in
            if let viewModel { splitSheet(target, viewModel) }
        }
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
                        // Live rows carry the selection tag; the Recently
                        // Deleted/Delisted rows below are selection-disabled
                        // so a tombstone can't take the visual selection.
                        speakerRow(speaker, viewModel: viewModel)
                            .tag(speaker.id)
                            // PT-R128: keyed on the stable spk_<ulid>, never
                            // the (renamable) speaker name. During inline-rename
                            // the row collapses to just the `TextField`, and this
                            // outer identifier would otherwise SHADOW that
                            // field's own `renameField` id (SwiftUI applies the
                            // outermost `.accessibilityIdentifier` to the single
                            // leaf AX element the row becomes, so the field
                            // surfaced under the row id). Expose `renameField`
                            // while the row is being renamed and the stable row
                            // id otherwise — identifier-only, no behavior change.
                            .accessibilityIdentifier(
                                renameTarget == speaker.id
                                    ? A11yID.Speakers.renameField
                                    : A11yID.Speakers.row(speaker.id))
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
                            // selection type) — opt the tombstones out
                            // explicitly so they can't take the selection.
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
            // A SwiftUI List is already an AX element (an outline/table) — the
            // identifier alone surfaces it; no `children: .contain` promotion.
            .accessibilityIdentifier(A11yID.Speakers.list)
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
            // Clicking away from the rename field commits like Save — the
            // standard inline-rename contract, matching the recordings list.
            // Commit only when the row LOSING focus is still the rename
            // target: Escape/Return clear `renameTarget` first (no-op here),
            // and a re-target flips it to the new row before the old field
            // resigns — committing then would close the new editor instantly.
            .onChange(of: focusedRenameID) { oldValue, _ in
                if oldValue == renameTarget { commitPendingRename(viewModel) }
            }
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
            // Task 7b — merging rewrites every final.md the merged-away
            // speaker appears in, so it is confirmed with the impact count
            // fetched when the context-menu item staged `pendingMerge`.
            // A second dialog on the same List is fine: delist and merge are
            // both staged from context-menu items, so only one can be up.
            .confirmationDialog(
                "Merge “\(pendingMerge?.otherName ?? "")” into "
                    + "“\(pendingMerge?.primaryName ?? "")”?",
                isPresented: Binding(
                    get: { pendingMerge != nil },
                    set: { if !$0 { pendingMerge = nil } })
            ) {
                Button("Merge", role: .destructive) {
                    if let merge = pendingMerge {
                        Task { await viewModel.merge(
                            primaryId: merge.primaryId,
                            otherId: merge.otherId) }
                    }
                    pendingMerge = nil
                }
                .accessibilityIdentifier(A11yID.Speakers.mergeConfirm)
            } message: {
                let count = pendingMerge?.count ?? 0
                Text("“\(pendingMerge?.otherName ?? "")” is folded into "
                    + "“\(pendingMerge?.primaryName ?? "")”. "
                    + "\(count) recording\(count == 1 ? "" : "s") will be rewritten.")
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

    /// The undo affordance shown after a destructive edit (PT-R44).
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
                    .accessibilityIdentifier(A11yID.Speakers.undoButton)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
                // PT-R128: the toast is a plain HStack in a safe-area inset —
                // a bare stack is not an AX element on macOS, so promote it to a
                // container (children: .contain) BEFORE the identifier so tests
                // can scope into it for the Undo button.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.Speakers.undoToast)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // `UndoToast` carries a non-Equatable `action` closure, so animate on
        // its presence (Bool) rather than on the value itself.
        .animation(.default, value: viewModel.undoToast != nil)
    }

    /// PT-R44 edge case — no speakers yet.
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
                    // PT-R128: the inline rename field (TextField is a
                    // first-class AX element — no promotion).
                    .accessibilityIdentifier(A11yID.Speakers.renameField)
                    .focused($focusedRenameID, equals: speaker.id)
                    .onAppear {
                        focusedRenameID = speaker.id
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
                    // Return saves, Escape cancels, clicking away saves —
                    // identical to the recordings-list rename. Escape clears
                    // `renameTarget` before the focus change lands, so the
                    // blur-commit no-ops on the cancel path.
                    .onSubmit { commitPendingRename(viewModel) }
                    .onExitCommand { renameTarget = nil }
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
                // Explicit selection — the same NSHostingView-eats-mouseDown
                // race documented on the recordings rows (RecordingsSplitView
                // .rowView): row content carrying a gesture consumes the
                // click, so the table's native selection fires only when
                // AppKit wins the race. Single-select makes this a plain
                // idempotent assignment; keyboard selection still flows
                // through the List binding.
                .simultaneousGesture(TapGesture().onEnded {
                    selection = speaker.id
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    // Re-targeting must not silently discard a pending edit
                    // on another row — commit it like Save (§6 note).
                    commitPendingRename(viewModel)
                    renameText = speaker.name
                    renameTarget = speaker.id
                })
                .contextMenu {
                    Button("Rename") {
                        commitPendingRename(viewModel)
                        renameText = speaker.name
                        renameTarget = speaker.id
                    }
                    // PT-R128: identifier-located, not by title.
                    .accessibilityIdentifier(A11yID.Speakers.renameButton)
                    // Merge/Split moved here from the toolbar (QA round 3):
                    // ⌘-click arming was undiscoverable, and the operand
                    // pickers were redundant once two speakers were already
                    // selected. The right-clicked speaker survives; the
                    // submenu picks who gets folded into them. The action
                    // only stages the confirmation (merging rewrites
                    // final.md files) — the dialog on the List performs it.
                    if viewModel.liveSpeakers.count > 1 {
                        Menu("Merge With") {
                            ForEach(viewModel.liveSpeakers.filter {
                                $0.id != speaker.id
                            }) { other in
                                Button(other.name) {
                                    Task {
                                        let count = await viewModel
                                            .appearances(ofSpeaker: other.id)
                                            .count
                                        pendingMerge = PendingMerge(
                                            primaryId: speaker.id,
                                            primaryName: speaker.name,
                                            otherId: other.id,
                                            otherName: other.name,
                                            count: count)
                                    }
                                }
                                // PT-R128: per-target, keyed on the folded-in
                                // speaker's id so the merge flow picks it by id.
                                .accessibilityIdentifier(
                                    A11yID.Speakers.mergeTarget(other.id))
                            }
                        }
                        .accessibilityIdentifier(A11yID.Speakers.mergeButton)
                    }
                    Button("Split…") {
                        splitNewName = ""
                        splitSelectedRecordingIds = []
                        splitTarget = speaker
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
                    .accessibilityIdentifier(A11yID.Speakers.deleteButton)
                }
            }
        }
    }

    /// Commit an in-progress rename like Save — wired to Return, focus loss,
    /// re-targeting, and navigation-away (§6 planning note: none of those may
    /// silently discard the edit). A blank name cancels instead of saving.
    private func commitPendingRename(_ viewModel: SpeakerEditorViewModel) {
        guard let id = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty else { return }
        Task { await viewModel.rename(speakerId: id, to: name) }
    }

    // MARK: - Split

    /// The split sheet (#3) — name the new speaker and tick the recordings to
    /// move out of `target` (the right-clicked speaker; there is no source
    /// picker — the operand was chosen by where the menu was opened). The
    /// recording multi-select replaces the old free-text "comma-separated
    /// recording ids" field, which required the user to know opaque
    /// `rec_<short>` ids.
    @ViewBuilder
    private func splitSheet(
        _ target: Speaker, _ viewModel: SpeakerEditorViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split “\(target.name)”").font(.headline)
            TextField("New speaker name", text: $splitNewName)

            Text("Recordings to move to the new speaker")
                .font(.caption)
                .foregroundStyle(.secondary)
            SplitRecordingPicker(
                viewModel: viewModel,
                speakerId: target.id,
                selection: $splitSelectedRecordingIds)
                .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Cancel") { splitTarget = nil }
                Button("Split") {
                    if !splitSelectedRecordingIds.isEmpty {
                        Task {
                            await viewModel.split(
                                originalId: target.id,
                                movingRecordingIds: Array(splitSelectedRecordingIds),
                                newName: splitNewName)
                        }
                    }
                    splitTarget = nil
                }
                .disabled(
                    splitNewName.trimmingCharacters(in: .whitespaces).isEmpty
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
        // PT-P6-D1: use the single shared library `AppEnvironment` opened in
        // bootstrap (the same writer the MCP server uses) rather than opening a
        // second one. `nil` means the bootstrap open failed — surface the error
        // state, the same outcome `load` produced on a failed open.
        guard let library = await environment.sharedSpeakerLibrary() else {
            loadError = "The speaker library could not be opened."
            return
        }
        viewModel = await SpeakerEditorViewModel.using(
            library: library, events: events, settings: settings)
    }
}

/// The recording multi-select inside the split sheet (#3).
///
/// Loads the source speaker's appearances on appear and renders them as
/// toggleable rows. `speakerId` is fixed for the sheet's lifetime (the sheet
/// is item-driven), so `.task(id:)` effectively runs once per presentation —
/// the id form keeps the reload correct if the operand ever becomes mutable
/// again. Lives in its own view so the reload does not re-run the whole
/// split sheet.
private struct SplitRecordingPicker: View {
    let viewModel: SpeakerEditorViewModel
    /// The source speaker whose recordings can be moved — always the sheet's
    /// item, so never stale or missing.
    let speakerId: String
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
    /// recording from a previously-split speaker cannot leak into the split.
    private func reload() async {
        loaded = false
        selection = []
        appearances = await viewModel.appearances(ofSpeaker: speakerId)
        loaded = true
    }
}
