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

                TextField("Restrict to languages",
                          text: $settings.allowedLanguagesRaw,
                          prompt: Text("e.g., en, pl"))
                Text("Comma-separated ISO-639-1 codes. Leave empty to let "
                    + "whisper auto-detect freely. With a list, every "
                    + "window's language is forced to the highest-"
                    + "probability code from your list.")
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
                Text(settings.globalHotkey.map { "Hotkey set (key \($0.keyCode))" }
                    ?? "No global hotkey set")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A window toolbar so this pane's split-view chrome (corner rounding,
        // sidebar extent) matches the Recordings and Speakers panes — those
        // carry a toolbar; a pane without one renders different chrome.
        .toolbar {
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
