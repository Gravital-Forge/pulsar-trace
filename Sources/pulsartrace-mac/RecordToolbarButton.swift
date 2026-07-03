import PulsarTraceMenuBar
import SwiftUI

/// The shared Record/Stop toolbar control (§6), present on every pane (also
/// reused as the Recordings empty-state CTA).
///
/// Navigation and auto-select are scoped to the BUTTON ACTION, not the
/// status transition: a hotkey- or menubar-started recording must not steal
/// the window's selection or section (§6 — review finding).
///
/// Environment coupling: the Recordings empty-state CTA re-injects this
/// view's dependencies explicitly (it sits below an NSHostingView boundary
/// — see `RecordingsListPane`). A new `@Environment` dependency here must
/// also be re-injected there or that path crashes at runtime.
struct RecordToolbarButton: View {
    @Environment(RecordingViewModel.self) private var recording
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        control
            // PT-P7-R3: one identifier across every visual state
            // (Record / Starting… / Stop / disabled), deliberately distinct
            // from the panel's `recordToggle` so a query never matches across
            // surfaces when the panel and window are both open.
            .accessibilityIdentifier(A11yID.Window.recordToolbar)
    }

    @ViewBuilder private var control: some View {
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
            .help("Starting recording…")
            .accessibilityLabel("Starting recording")
        case .recording(_, let startedAt):
            // Phase from `startedAt` so the tick lands on true second
            // rollovers (and in unison with the menubar timer).
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Button {
                    Task { await recording.stopRecording() }
                } label: {
                    Label("Stop · \(elapsedTimeString(from: startedAt, to: context.date))",
                          systemImage: "stop.circle.fill")
                        .monospacedDigit()
                }
                .tint(.red)
                .help("Stop recording")
                // Stable label for VoiceOver — the ticking time is the value.
                .accessibilityLabel("Stop recording")
                .accessibilityValue(elapsedTimeString(from: startedAt, to: context.date))
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
    /// flips. On failure the section switch still happens — the `.error`
    /// banner lives on the Recordings pane, so navigating there is what
    /// shows the user why the start failed.
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
