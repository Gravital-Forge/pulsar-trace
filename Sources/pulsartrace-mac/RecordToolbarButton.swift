import PulsarTraceMenuBar
import SwiftUI

/// The shared Record/Stop toolbar control (§6), present on all three panes.
///
/// Navigation and auto-select are scoped to the BUTTON ACTION, not the
/// status transition: a hotkey- or menubar-started recording must not steal
/// the window's selection or section (§6 — review finding).
struct RecordToolbarButton: View {
    @Environment(RecordingViewModel.self) private var recording
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        switch recording.status {
        case .idle:
            Button(action: startFromButton) {
                Label("Record", systemImage: "record.circle.fill")
            }
            .help("Start recording")
        case .launching:
            Button {} label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                }
            }
            .disabled(true)
        case .recording(_, let startedAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    Task { await recording.stopRecording() }
                } label: {
                    Label("Stop · \(elapsedTimeString(from: startedAt, to: context.date))",
                          systemImage: "stop.circle.fill")
                        .monospacedDigit()
                }
                .tint(.red)
                .help("Stop recording")
            }
        case .crashed:
            disabledRecord(reason: "Recording stopped unexpectedly — recover or dismiss in the Recordings pane.")
        case .error(let message):
            disabledRecord(reason: message)
        }
    }

    private func disabledRecord(reason: String) -> some View {
        Button {} label: {
            Label("Record", systemImage: "record.circle.fill")
        }
        .disabled(true)
        .help(reason)
    }

    /// §6: pressing Record navigates to Recordings and selects the live row
    /// — a direct response to the click. `startRecording()` returns only
    /// after the status settled (`.recording` or `.error`), so the id is
    /// readable right here; the synthesized row exists the moment status
    /// flips.
    private func startFromButton() {
        Task {
            await recording.startRecording()
            navigation.section = .recordings
            if case .recording(let id, _) = recording.status {
                navigation.selectedRecordingID = id
            }
        }
    }
}
