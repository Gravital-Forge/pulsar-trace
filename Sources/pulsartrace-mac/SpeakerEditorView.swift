import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The speaker editor (R44) — list, inline rename, merge/split/delete, undo
/// toast, recently-deleted section. Pure bindings over `SpeakerEditorViewModel`.
///
/// The `SpeakerLibrary` actor is opened asynchronously on appear (its init is
/// `async throws`), so this view owns the optional ViewModel and shows a
/// loading state until it resolves — or an error state if the open fails.
struct SpeakerEditorView: View {
    let settings: MenuBarSettings
    /// The process-wide events writer — wired into the ViewModel so speaker
    /// edits emit `speaker_*` / `final_md_rewritten` events in the shipped app.
    let events: EventWriter
    /// Invoked by the "Back" button. Inline navigation in `MenuBarMenuView`
    /// (FIX 2) — the view no longer relies on `@Environment(\.dismiss)`, which
    /// did not work predictably for a sheet on a `MenuBarExtra` panel.
    var onClose: () -> Void

    @State private var viewModel: SpeakerEditorViewModel?
    /// Set when opening the speaker library fails — shows an error state
    /// instead of an indefinite "Loading…".
    @State private var loadError: String?
    @State private var renameTarget: String?
    @State private var renameText = ""

    // Merge sheet state.
    @State private var showMerge = false
    @State private var mergePrimaryId: String?
    @State private var mergeOtherId: String?

    // Split sheet state.
    @State private var showSplit = false
    @State private var splitOriginalId: String?
    @State private var splitNewName = ""
    @State private var splitRecordingIds = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { onClose() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                Text("Speakers").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            if let viewModel {
                content(viewModel)
            } else if let loadError {
                errorState(loadError)
            } else {
                ProgressView("Loading speaker library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 440, height: 420)
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
        if let error = viewModel.lastError {
            Text(error).foregroundStyle(.red).padding(8)
        }
        if viewModel.liveSpeakers.isEmpty && viewModel.deletedSpeakers.isEmpty {
            emptyState
        } else {
            List {
                Section("Speakers") {
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
            }
            // R31 — merge / split entry points (thin bindings; the ViewModel
            // owns all logic).
            HStack {
                Button("Merge…") {
                    mergePrimaryId = viewModel.liveSpeakers.first?.id
                    mergeOtherId = viewModel.liveSpeakers.dropFirst().first?.id
                    showMerge = true
                }
                .disabled(viewModel.liveSpeakers.count < 2)
                Button("Split…") {
                    splitOriginalId = viewModel.liveSpeakers.first?.id
                    splitNewName = ""
                    splitRecordingIds = ""
                    showSplit = true
                }
                .disabled(viewModel.liveSpeakers.isEmpty)
                Spacer()
            }
            .padding(8)
        }
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
            .padding(8)
            .background(.thinMaterial)
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
                    .onSubmit {
                        Task {
                            await viewModel.rename(
                                speakerId: speaker.id, to: renameText)
                            renameTarget = nil
                        }
                    }
            } else {
                Text(speaker.name)
                Spacer()
                Button("Rename") {
                    renameText = speaker.name
                    renameTarget = speaker.id
                }
                Button("Delete") {
                    Task { await viewModel.delete(speakerId: speaker.id) }
                }
            }
        }
    }

    // MARK: - Merge sheet

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

    // MARK: - Split sheet

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
            TextField(
                "Recording ids to move (comma-separated)",
                text: $splitRecordingIds)
            HStack {
                Spacer()
                Button("Cancel") { showSplit = false }
                Button("Split") {
                    let ids = splitRecordingIds
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if let original = splitOriginalId, !ids.isEmpty {
                        Task {
                            await viewModel.split(
                                originalId: original,
                                movingRecordingIds: ids,
                                newName: splitNewName)
                        }
                    }
                    showSplit = false
                }
                .disabled(splitOriginalId == nil
                    || splitNewName.trimmingCharacters(in: .whitespaces).isEmpty
                    || splitRecordingIds.trimmingCharacters(in: .whitespaces)
                        .isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    /// Open the `SpeakerLibrary` at the standard app-support path and build the
    /// ViewModel. A failure surfaces an error state (I6) instead of an
    /// indefinite loading spinner.
    private func loadLibrary() async {
        guard viewModel == nil else { return }
        let paths = AppPaths.standard
        do {
            let library = try await SpeakerLibrary(
                databaseURL: paths.speakersDatabaseURL, events: events)
            let vm = SpeakerEditorViewModel(
                library: library, events: events, settings: settings)
            await vm.reload()
            viewModel = vm
        } catch {
            loadError = "\(error)"
        }
    }
}
