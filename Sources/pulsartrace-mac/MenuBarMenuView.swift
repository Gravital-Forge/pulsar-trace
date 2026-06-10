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
    @Environment(RefinementJobQueueViewModel.self) private var queueVM
    @Environment(AppNavigation.self) private var navigation
    @Environment(MenuBarSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            // A determinate bar under the status line while a refinement is
            // running — same data the "Refining N% · Stage" text reads, just
            // visual. Padding matches the status text so the bar spans the
            // panel's content width.
            if let progress = runningProgress {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: progress.fraction)
                        .controlSize(.small)
                    Text(progress.stageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            menuDivider

            recordControls

            menuDivider

            menuButton("Recordings…") { open(WindowID.main, section: .recordings) }
            menuButton("Speakers…") { open(WindowID.main, section: .speakers) }
            menuButton("Settings…") { open(WindowID.main, section: .settings) }

            menuDivider

            // ⌘Q works while the panel is open (the panel is the key window).
            menuButton("Quit PulsarTrace", shortcut: KeyboardShortcut("q")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 250)
    }

    /// Start/stop plus the state-specific actions (live transcript, crash
    /// recovery). One `@ViewBuilder` switch over the recording state.
    @ViewBuilder private var recordControls: some View {
        switch recording.status {
        case .idle:
            menuButton("Start Recording", hint: hotkeyHint) {
                Task { await recording.startRecording() }
            }
        case .launching:
            menuButton("Starting…", enabled: false) {}
        case .recording:
            menuButton("Stop Recording", hint: hotkeyHint) {
                Task { await recording.stopRecording() }
            }
            menuButton("Show Live Transcript…") {
                open(WindowID.liveTranscript)
            }
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
    ///
    /// `hint` renders trailing secondary text (the global-hotkey glyphs on
    /// Start/Stop); `shortcut` registers a local keyboard shortcut for the
    /// row (⌘Q on Quit).
    private func menuButton(
        _ title: String,
        hint: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                if let hint {
                    Spacer()
                    Text(hint)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .keyboardShortcut(shortcut)
        .disabled(!enabled)
    }

    /// The configured global hotkey as glyphs (e.g. ⇧⌘R) for the Start/Stop
    /// row hint; `nil` (no hint) when no hotkey is set.
    private var hotkeyHint: String? {
        settings.globalHotkey.map(KeyComboFormatter.displayString(for:))
    }

    /// A divider inset to match the row padding.
    private var menuDivider: some View {
        Divider().padding(.vertical, 3)
    }

    /// The single status line (#1) — driven by `RecordingStatus` with a queue
    /// overlay when a refinement is running or queued in the background.
    /// `progressMessage` is consulted only when idle: a failed refine leaves a
    /// message there that would otherwise be lost.
    private var statusText: String {
        switch recording.status {
        case .recording(_, let startedAt):
            let started = startedAt.formatted(date: .omitted, time: .shortened)
            if let q = queueStatus { return "Recording since \(started) · \(q)" }
            return "Recording since \(started)"
        case .idle:
            if let q = queueStatus { return q }
            return recording.progressMessage.isEmpty
                ? "Ready" : recording.progressMessage
        case .launching: return "Starting…"
        case .crashed:   return "Recording stopped unexpectedly"
        case .error(let message): return message
        }
    }

    /// A short queue summary to append to or replace the status line.
    /// Returns `nil` when the queue is idle so the recording status stands alone.
    private var queueStatus: String? {
        if let running = queueVM.running,
           case .running(let stage, _, _, _, _) = running.state {
            if let pct = running.state.progressFraction {
                return "Refining \(Int((pct * 100).rounded()))% · \(stage.displayName)"
            }
            return "Refining · \(stage.displayName)"
        }
        if !queueVM.queued.isEmpty {
            return "\(queueVM.queued.count) queued"
        }
        return nil
    }

    /// Raw fraction + stage for the determinate bar — the same
    /// `queueVM.running` state `queueStatus` reads, kept numeric rather than
    /// re-parsed out of the composed status string.
    private var runningProgress: (fraction: Double, stageName: String)? {
        guard let running = queueVM.running,
              case .running(let stage, _, _, _, _) = running.state,
              let fraction = running.state.progressFraction
        else { return nil }
        return (fraction, stage.displayName)
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
