import AppKit
import PulsarTraceCapture
import PulsarTraceEngine
import PulsarTraceMCP
import PulsarTraceMenuBar
import SwiftUI

/// The Settings pane (PT-R42, PT-R43, PT-R41) — mic, model, output folder, hotkey,
/// system-audio toggle. Pure bindings over `MenuBarSettings`.
///
/// Rendered as a detail pane of `MainWindowView`'s sidebar window (#6) — it no
/// longer backs a standalone `Settings` scene, so it carries no fixed frame
/// and fills the detail column.
struct SettingsView: View {
    @Environment(MenuBarSettings.self) private var settings
    /// The opt-in MCP server lifecycle owner (PT-P6-R1), injected by the app.
    @Environment(MCPController.self) private var mcp
    /// Whether the languages popover is currently shown — the popup-button
    /// click toggles this; clicking outside dismisses.
    @State private var languagePopoverOpen = false
    /// Live filter inside the popover. Reset to empty when the popover
    /// reopens so the user starts fresh each time.
    @State private var languageFilter = ""
    /// Last `/healthz` probe result (PT-P6-R11) — the live status, not an
    /// in-memory flag.
    @State private var mcpStatus: MCPServerStatus = .stopped
    /// The server's bearer token, surfaced so the setup snippet is paste-ready.
    @State private var mcpToken: String = ""

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
                Picker("Refinement model",
                       selection: $settings.refineModelName) {
                    ForEach(WhisperKitModelCatalog.all.map(\.name), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Text("Runs on the Neural Engine — recording never competes "
                    + "with Meet or screen-share for the GPU. large-v3-turbo "
                    + "is the fast default (~626 MB download on first use); "
                    + "large-v3-whisperkit is the slower accuracy fallback "
                    + "(~947 MB). Live transcription always uses Parakeet v3 "
                    + "(~0.5 GB on first recording).")
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
                Text("Applies to both passes. Pick exactly one language to "
                    + "pin refinement to it and steer live transcription "
                    + "toward its script. Pick several and refinement "
                    + "detects the best match among them per turn (live "
                    + "stays auto). Leave empty for full auto-detect. "
                    + "Live picks up changes at the next recording; "
                    + "refinements run with the languages in effect at the "
                    + "last app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                LabeledContent("Location") {
                    HStack {
                        Text(settings.outputFolderURL?.path ?? "No folder chosen")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseOutputFolder() }
                    }
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

            // PT-P6-R1 / PT-P6-R11: the opt-in agent control surface. Disabled
            // by default; shows the live `/healthz` status, the paste-ready
            // setup command, and a manual restart.
            Section("MCP Server (agent control surface)") {
                Toggle("Enable MCP server", isOn: $settings.mcpServerEnabled)
                LabeledContent("Port") {
                    TextField("8276", value: $settings.mcpServerPort,
                              format: .number.grouping(.never))
                        .frame(width: 80)
                }
                LabeledContent("Status") {
                    Text(statusText(mcpStatus)).foregroundStyle(.secondary)
                }
                if settings.mcpServerEnabled, !mcpToken.isEmpty {
                    LabeledContent("Connect") {
                        HStack {
                            Text(MCPConnectionSnippet.endpoint(
                                port: UInt16(settings.mcpServerPort)))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Button("Copy setup command") {
                                let snippet = MCPConnectionSnippet.claudeCode(
                                    port: UInt16(settings.mcpServerPort), token: mcpToken)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(snippet, forType: .string)
                            }
                        }
                    }
                    Button("Restart server") {
                        Task { await mcp.restart(); await refreshMCP() }
                    }
                }
                Text("A local-only control surface an agent can drive over "
                    + "loopback (127.0.0.1). Off by default; every request is "
                    + "bearer-authenticated. Copy the setup command into your "
                    + "agent to connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: settings.mcpServerEnabled) { await refreshMCP() }
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

    /// Refresh the MCP token + live `/healthz` status (PT-P6-R11). Probes the
    /// real socket so Settings reflects whether it is actually accepting.
    private func refreshMCP() async {
        mcpToken = await mcp.token()
        mcpStatus = await MCPHealthProbe.probe(port: UInt16(settings.mcpServerPort))
    }

    /// Human-readable form of the probed server status (PT-P6-R11).
    private func statusText(_ s: MCPServerStatus) -> String {
        switch s {
        case .stopped: return "Stopped"
        case .running(let p): return "Running on 127.0.0.1:\(p)"
        case .portInUse(let p): return "Port \(p) is in use — pick another port"
        case .failed(let r): return "Stopped — \(r)"
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
    private var filteredLanguages: [LanguageCatalog.Language] {
        let needle = languageFilter
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if needle.isEmpty { return LanguageCatalog.all }
        return LanguageCatalog.all.filter {
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
                settings.allowedLanguages = LanguageCatalog.all
                    .map(\.code)
                    .filter { selected.contains($0) }
            })
    }

    /// Header summary of the language picker: either "any (auto-detect)"
    /// or the comma-joined display names of the selected codes.
    private var allowedLanguagesSummary: String {
        let selected = Set(settings.allowedLanguages)
        if selected.isEmpty { return "any (auto-detect)" }
        let names = LanguageCatalog.all
            .filter { selected.contains($0.code) }
            .map(\.displayName)
        return names.joined(separator: ", ")
    }

    /// Open an `NSOpenPanel`, store the chosen folder as a plain filesystem
    /// path (PT-P2-D12), and keep the prior folder in `previousFolderPaths`.
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
