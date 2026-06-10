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
    /// Drives the rename `TextField`'s first-responder state — set on appear so
    /// the cursor visibly lands in the field, paired with a select-all so the
    /// existing name is highlighted and typing replaces it in one keystroke.
    @FocusState private var renameFieldFocused: Bool

    // Merge sheet state.
    @State private var showMerge = false
    @State private var mergePrimaryId: String?
    @State private var mergeOtherId: String?

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
            // Always present (disabled until usable) so the window toolbar —
            // and thus the chrome — does not change as the library loads.
            ToolbarItemGroup {
                Button("Merge…") {
                    if let viewModel { startMerge(viewModel) }
                }
                .disabled((viewModel?.liveSpeakers.count ?? 0) < 2)
                Button("Split…") {
                    if let viewModel { startSplit(viewModel) }
                }
                .disabled(viewModel?.liveSpeakers.isEmpty ?? true)
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

    @ViewBuilder
    private func content(_ viewModel: SpeakerEditorViewModel) -> some View {
        if viewModel.liveSpeakers.isEmpty
            && viewModel.deletedSpeakers.isEmpty
            && viewModel.delistedSpeakers.isEmpty {
            emptyState
        } else {
            List {
                // Untitled — the pane's navigation title already says
                // "Speakers"; a `Section("Speakers")` header here was a
                // duplicate label.
                Section {
                    ForEach(viewModel.liveSpeakers) { speaker in
                        speakerRow(speaker, viewModel: viewModel)
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
                        }
                    }
                }
            }
            .overlay(alignment: .top) { errorBanner(viewModel) }
            .overlay(alignment: .bottom) { undoBanner(viewModel) }
        }
    }

    /// A transient error banner for a failed edit (`viewModel.lastError`).
    @ViewBuilder
    private func errorBanner(_ viewModel: SpeakerEditorViewModel) -> some View {
        if let error = viewModel.lastError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
        }
    }

    /// The undo affordance shown after a destructive edit (R44).
    @ViewBuilder
    private func undoBanner(_ viewModel: SpeakerEditorViewModel) -> some View {
        if let toast = viewModel.undoToast {
            HStack {
                Text(toast.message)
                Spacer()
                Button("Undo") {
                    Task {
                        await toast.action()
                        viewModel.undoToast = nil
                    }
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
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
                Text(speaker.name)
                Spacer()
                Button("Rename") {
                    renameText = speaker.name
                    renameTarget = speaker.id
                }
                // "Don't recognize this speaker" — hidden for the mic speaker
                // (name `"You"`), matching the ViewModel's mic-rejection guard.
                // The library doesn't carry an `isMicrophone` flag on a
                // `Speaker` today, so the UI mirrors the same name-based
                // policy. See SpeakerEditorViewModel.delist for the rationale.
                if speaker.name != "You" {
                    Button("Don't recognize") {
                        Task { await viewModel.delist(speakerId: speaker.id) }
                    }
                    .help("Stop recognizing this speaker. Their lines in "
                        + "transcripts become 'Unrecognized'. Undoable for "
                        + "30 days.")
                }
                Button("Delete") {
                    Task { await viewModel.delete(speakerId: speaker.id) }
                }
            }
        }
    }

    // MARK: - Merge

    /// Seed the merge sheet's pickers and present it.
    private func startMerge(_ viewModel: SpeakerEditorViewModel) {
        mergePrimaryId = viewModel.liveSpeakers.first?.id
        mergeOtherId = viewModel.liveSpeakers.dropFirst().first?.id
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
                Button("Merge") {
                    if let primary = mergePrimaryId,
                       let other = mergeOtherId, primary != other {
                        Task {
                            await viewModel.merge(
                                primaryId: primary, otherId: other)
                        }
                    }
                    showMerge = false
                }
                .disabled(mergePrimaryId == nil || mergeOtherId == nil
                    || mergePrimaryId == mergeOtherId)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Split

    /// Seed the split sheet and present it.
    private func startSplit(_ viewModel: SpeakerEditorViewModel) {
        splitOriginalId = viewModel.liveSpeakers.first?.id
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
                .frame(height: 160)

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
        .frame(width: 380)
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
