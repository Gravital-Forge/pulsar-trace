import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The menubar dropdown (R40) — start/stop, status, and entry points into the
/// recordings list, the live transcript, and the speaker editor.
///
/// Navigation (FIX 2): the sub-views render **inline within this same
/// `MenuBarExtra` panel** via a `@State` page enum and a "Back" button — no
/// `.sheet`. A sheet on a `MenuBarExtra` panel positioned janky sub-windows
/// (off-screen near the right edge) and left the panel in a "weird state"
/// where re-opening the menubar icon re-showed the sub-view instead of the
/// menu. Inline pages always render inside the panel macOS itself positions,
/// and the panel resets to `.menu` every time it is dismissed and re-opened.
struct MenuBarMenuView: View {
    /// The process-wide events writer — handed to the speaker editor so its
    /// `speaker_*` / `final_md_rewritten` events are emitted in the shipped
    /// app (the events-log public contract).
    let events: EventWriter

    @Environment(MenuBarSettings.self) private var settings
    @Environment(RecordingViewModel.self) private var recording
    @Environment(RecordingsScanner.self) private var scanner
    @Environment(LiveTranscriptWatcher.self) private var liveWatcher

    /// The panel's environment — used to reset to `.menu` whenever the panel
    /// is dismissed, so re-opening the menubar icon always shows the menu.
    @Environment(\.controlActiveState) private var controlActiveState

    /// Which page the panel currently shows. Inline navigation (FIX 2).
    private enum Page {
        case menu, recordings, live, speakers
    }
    @State private var page: Page = .menu

    var body: some View {
        Group {
            switch page {
            case .menu:
                menuPage
            case .recordings:
                RecordingsListView(onClose: { page = .menu })
                    .environment(scanner)
            case .live:
                LiveTranscriptPopoverView(onClose: { page = .menu })
                    .environment(liveWatcher)
            case .speakers:
                SpeakerEditorView(
                    settings: settings, events: events,
                    onClose: { page = .menu })
            }
        }
        // When the panel loses key (the user clicked away / it closed), snap
        // back to the menu so the next open always starts on the menu (FIX 2).
        .onChange(of: controlActiveState) { _, newValue in
            if newValue == .inactive { page = .menu }
        }
    }

    // MARK: - Menu page

    private var menuPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PulsarTrace")
                .font(.headline)

            statusLine

            Divider()

            recordButton

            if case .recording = recording.status {
                Button("Live Transcript…") { page = .live }
            }
            if case .crashed = recording.status {
                crashRecovery
            }

            Divider()

            Button("Recordings…") { page = .recordings }
            Button("Speakers…") { page = .speakers }

            Divider()

            SettingsLink { Text("Settings…") }
            Button("Quit PulsarTrace") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    @ViewBuilder private var statusLine: some View {
        switch recording.status {
        case .idle:
            Text("Ready").foregroundStyle(.secondary)
        case .launching:
            Text("Starting…").foregroundStyle(.secondary)
        case .recording(_, let startedAt):
            Text("Recording — started \(startedAt.formatted(date: .omitted, time: .shortened))")
        case .refining:
            Text("Refining transcript…").foregroundStyle(.secondary)
        case .crashed:
            Text("Recording stopped unexpectedly")
                .foregroundStyle(.orange)
        case .error(let message):
            Text(message).foregroundStyle(.red)
        }
        if !recording.progressMessage.isEmpty {
            Text(recording.progressMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var recordButton: some View {
        switch recording.status {
        case .idle:
            Button("Start Recording") {
                Task { await recording.startRecording() }
            }
        case .recording:
            Button("Stop Recording") {
                Task { await recording.stopRecording() }
            }
        case .error:
            Button("Dismiss") { recording.dismissCrash() }
        default:
            Button("Start Recording") {}.disabled(true)
        }
    }

    @ViewBuilder private var crashRecovery: some View {
        Button("Recover Transcript") {
            Task { await recording.recoverFromCrash() }
        }
        Button("Dismiss") { recording.dismissCrash() }
    }
}
