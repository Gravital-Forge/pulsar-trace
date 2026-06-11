import AppKit
import PulsarTraceCapture
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The Settings pane (R42, R43, R41) — mic, model, output folder, hotkey,
/// system-audio toggle. Pure bindings over `MenuBarSettings`.
///
/// Rendered as a detail pane of `MainWindowView`'s sidebar window (#6) — it no
/// longer backs a standalone `Settings` scene, so it carries no fixed frame
/// and fills the detail column.
struct SettingsView: View {
    @Environment(MenuBarSettings.self) private var settings
    /// Whether the languages popover is currently shown — the popup-button
    /// click toggles this; clicking outside dismisses.
    @State private var languagePopoverOpen = false
    /// Live filter inside the popover. Reset to empty when the popover
    /// reopens so the user starts fresh each time.
    @State private var languageFilter = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Audio") {
                Picker("Microphone", selection: micBinding) {
                    Text("System Default").tag(String?.none)
                    ForEach(AudioInputDevices.available(), id: \.uniqueID) { device in
                        Text(device.name).tag(String?.some(device.uniqueID))
                    }
                }
                Toggle("Capture system audio", isOn: $settings.systemAudioEnabled)
            }

            Section("Transcription") {
                Picker("Live transcription model",
                       selection: $settings.liveModelName) {
                    ForEach(ModelCatalog.all, id: \.name) { model in
                        Text(model.name).tag(model.name)
                    }
                }
                Picker("Refinement model",
                       selection: $settings.refineModelName) {
                    ForEach(ModelCatalog.all, id: \.name) { model in
                        Text(model.name).tag(model.name)
                    }
                }
                Text("large-v3 is higher quality and ~3 GB — it downloads on "
                    + "first use if not already cached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Restrict to languages")
                    Spacer()
                    Button {
                        languageFilter = ""
                        languagePopoverOpen.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(allowedLanguagesSummary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $languagePopoverOpen,
                             arrowEdge: .top) {
                        languagePopoverContent
                    }
                }
                Text("Leave empty to let whisper auto-detect freely. With "
                    + "a selection, every window's language is forced to "
                    + "the highest-probability code from your list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                HStack {
                    Text(settings.outputFolderURL?.path ?? "No folder chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseOutputFolder() }
                }
            }

            Section("Shortcut") {
                HStack {
                    Text("Global record shortcut")
                    Spacer()
                    HotkeyRecorderField(combo: $settings.globalHotkey)
                    Button("Clear") { settings.globalHotkey = nil }
                        .disabled(settings.globalHotkey == nil)
                }
                Text("Toggles recording from anywhere. Click the field, then "
                    + "press a key with at least one of ⌃⌥⇧⌘.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A window toolbar so this pane's split-view chrome (corner rounding,
        // sidebar extent) matches the Recordings and Speakers panes — those
        // carry a toolbar; a pane without one renders different chrome.
        .toolbar {
            ToolbarItem(placement: .navigation) { RecordToolbarButton() }
            ToolbarItem {
                Button {
                    if let url = settings.outputFolderURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Reveal Output Folder", systemImage: "folder")
                }
                .disabled(settings.outputFolderURL == nil)
                .help("Reveal the output folder in Finder")
            }
        }
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { settings.selectedMicDeviceID },
            set: { settings.selectedMicDeviceID = $0 })
    }

    /// Contents of the languages popover: a search field on top and a
    /// scrollable list of checkboxes underneath. The popover stays open
    /// across multiple toggles so the user can pick `en` and `pl` in one
    /// session — `Menu`'s close-on-tap was the reason we did not use a
    /// pull-down menu here.
    private var languagePopoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter…", text: $languageFilter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLanguages) { lang in
                        Toggle(lang.displayName,
                               isOn: languageBinding(for: lang.code))
                            .toggleStyle(.checkbox)
                    }
                    if filteredLanguages.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 260, height: 320)
    }

    /// Languages that pass the current `languageFilter`. The match is a
    /// case-insensitive substring on the display name **or** the
    /// short code, so typing "pol" or "pl" both surface Polish.
    private var filteredLanguages: [WhisperLanguageCatalog.Language] {
        let needle = languageFilter
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if needle.isEmpty { return WhisperLanguageCatalog.all }
        return WhisperLanguageCatalog.all.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.code.contains(needle)
        }
    }

    /// Per-language `Toggle` binding: reads membership in
    /// `settings.allowedLanguages`, writes by adding or removing the code.
    /// The stored array is rewritten in catalog order on every change so
    /// the persisted list stays deterministic regardless of click order.
    private func languageBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { settings.allowedLanguages.contains(code) },
            set: { isOn in
                var selected = Set(settings.allowedLanguages)
                if isOn { selected.insert(code) } else { selected.remove(code) }
                settings.allowedLanguages = WhisperLanguageCatalog.all
                    .map(\.code)
                    .filter { selected.contains($0) }
            })
    }

    /// Header summary of the language picker: either "any (auto-detect)"
    /// or the comma-joined display names of the selected codes.
    private var allowedLanguagesSummary: String {
        let selected = Set(settings.allowedLanguages)
        if selected.isEmpty { return "any (auto-detect)" }
        let names = WhisperLanguageCatalog.all
            .filter { selected.contains($0.code) }
            .map(\.displayName)
        return names.joined(separator: ", ")
    }

    /// Open an `NSOpenPanel`, store the chosen folder as a plain filesystem
    /// path (D30), and keep the prior folder in `previousFolderPaths`.
    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let previous = settings.outputFolderPath {
            settings.previousFolderPaths.append(previous)
        }
        settings.outputFolderPath = url.path
    }
}
