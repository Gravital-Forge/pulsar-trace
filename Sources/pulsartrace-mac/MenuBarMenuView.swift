import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// The menubar dropdown (R40) — start/stop, a one-line status, and entry
/// points into the unified app window and the live-transcript window.
///
/// Rendered with `.menuBarExtraStyle(.window)`: a SwiftUI panel, not a native
/// `NSMenu`. The `.menu` style would give a truly native dropdown, but on this
/// app it rendered an empty/non-appearing menu — so the panel style (which
/// works reliably here) is used, with `MenuRowButtonStyle` restyling the rows
/// to read as a clean dropdown list rather than bordered buttons (#2).
struct MenuBarMenuView: View {
    @Environment(RecordingViewModel.self) private var recording
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            menuDivider

            recordControls

            menuDivider

            menuButton("Recordings…") { open(WindowID.main, section: .recordings) }
            menuButton("Speakers…") { open(WindowID.main, section: .speakers) }
            menuButton("Settings…") { open(WindowID.main, section: .settings) }

            menuDivider

            menuButton("Quit PulsarTrace") { NSApplication.shared.terminate(nil) }
        }
        .padding(6)
        .frame(width: 250)
    }

    /// Start/stop plus the state-specific actions (live transcript, crash
    /// recovery). One `@ViewBuilder` switch over the recording state.
    @ViewBuilder private var recordControls: some View {
        switch recording.status {
        case .idle:
            menuButton("Start Recording") {
                Task { await recording.startRecording() }
            }
        case .launching:
            menuButton("Starting…", enabled: false) {}
        case .recording:
            menuButton("Stop Recording") {
                Task { await recording.stopRecording() }
            }
            menuButton("Show Live Transcript…") {
                open(WindowID.liveTranscript)
            }
        case .refining:
            menuButton("Refining…", enabled: false) {}
        case .crashed:
            menuButton("Recover Transcript") {
                Task { await recording.recoverFromCrash() }
            }
            menuButton("Dismiss") { recording.dismissCrash() }
        case .error:
            menuButton("Dismiss") { recording.dismissCrash() }
        }
    }

    /// One dropdown row — a full-width, hover-highlighted button (#2).
    private func menuButton(
        _ title: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(MenuRowButtonStyle())
            .disabled(!enabled)
    }

    /// A divider inset to match the row padding.
    private var menuDivider: some View {
        Divider().padding(.vertical, 3)
    }

    /// The single status line (#1) — driven entirely by `RecordingStatus`, so
    /// the menu no longer stacks a redundant `progressMessage` line beneath it.
    /// `progressMessage` is consulted only when idle: a failed refine leaves a
    /// message there that would otherwise be lost.
    private var statusText: String {
        switch recording.status {
        case .idle:
            return recording.progressMessage.isEmpty
                ? "Ready" : recording.progressMessage
        case .launching:
            return "Starting…"
        case .recording(_, let startedAt):
            let started = startedAt.formatted(date: .omitted, time: .shortened)
            return "Recording since \(started)"
        case .refining:
            return "Refining transcript…"
        case .crashed:
            return "Recording stopped unexpectedly"
        case .error(let message):
            return message
        }
    }

    /// Colour for the status line — red/orange keep a crash or error salient
    /// rather than letting it read as ordinary secondary text.
    private var statusColor: Color {
        switch recording.status {
        case .error: return .red
        case .crashed: return .orange
        default: return .secondary
        }
    }

    /// Open an auxiliary window and bring the app forward.
    ///
    /// `NSApp.activate()` is required: PulsarTrace is an accessory-policy
    /// process (no Dock icon, D27), so a freshly-opened window does not become
    /// key on its own. When opening the unified window, the target sidebar
    /// section is set first so it lands on the pane the user picked.
    private func open(_ id: String, section: AppSection? = nil) {
        if let section { navigation.section = section }
        openWindow(id: id)
        NSApp.activate()
    }
}

/// A button style that renders a menubar-dropdown row (#2): full-width,
/// left-aligned, with an accent-coloured highlight on hover — so the panel
/// reads as a native-looking menu list instead of a stack of bordered buttons.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            // Highlight only an enabled row the pointer is over.
            let highlighted = hovering && isEnabled
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .foregroundStyle(foreground(highlighted: highlighted))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(highlighted ? Color.accentColor : .clear))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }

        private func foreground(highlighted: Bool) -> Color {
            if !isEnabled { return .secondary }
            return highlighted ? .white : .primary
        }
    }
}
