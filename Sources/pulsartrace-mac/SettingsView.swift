import AppKit
import PulsarTraceCapture
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The Settings scene (R42, R43, R41) — mic, model, output folder, hotkey,
/// system-audio toggle. Pure bindings over `MenuBarSettings`.
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
        .frame(width: 420, height: 340)
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { settings.selectedMicDeviceID },
            set: { settings.selectedMicDeviceID = $0 })
    }

    /// Open an `NSOpenPanel`, store the chosen folder as a security-scoped
    /// bookmark, and keep the prior folder in `previousFolderBookmarks`.
    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = try? MenuBarSettings.makeBookmark(for: url) else {
            return
        }
        if let previous = settings.outputFolderBookmark {
            settings.previousFolderBookmarks.append(previous)
        }
        settings.outputFolderBookmark = bookmark
    }
}
