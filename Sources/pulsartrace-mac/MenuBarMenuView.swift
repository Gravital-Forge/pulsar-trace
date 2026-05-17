import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// The menubar dropdown (R40) — start/stop, status, and entry points into the
/// recordings list, the live transcript, and the speaker editor.
struct MenuBarMenuView: View {
    /// The process-wide events writer — handed to the speaker editor so its
    /// `speaker_*` / `final_md_rewritten` events are emitted in the shipped
    /// app (the events-log public contract).
    let events: EventWriter

    @Environment(MenuBarSettings.self) private var settings
    @Environment(RecordingViewModel.self) private var recording
    @Environment(RecordingsScanner.self) private var scanner
    @Environment(LiveTranscriptWatcher.self) private var liveWatcher

    @State private var showRecordings = false
    @State private var showLive = false
    @State private var showSpeakers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PulsarTrace")
                .font(.headline)

            statusLine

            Divider()

            recordButton

            if case .recording = recording.status {
                Button("Live Transcript…") { showLive = true }
            }
            if case .crashed = recording.status {
                crashRecovery
            }

            Divider()

            Button("Recordings…") { showRecordings = true }
            Button("Speakers…") { showSpeakers = true }

            Divider()

            SettingsLink { Text("Settings…") }
            Button("Quit PulsarTrace") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
        .sheet(isPresented: $showRecordings) {
            RecordingsListView().environment(scanner)
        }
        .sheet(isPresented: $showLive) {
            LiveTranscriptPopoverView().environment(liveWatcher)
        }
        .sheet(isPresented: $showSpeakers) {
            SpeakerEditorView(settings: settings, events: events)
        }
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
