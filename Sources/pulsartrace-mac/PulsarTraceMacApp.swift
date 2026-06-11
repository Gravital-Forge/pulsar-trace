import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// PulsarTrace's menubar app (D27).
///
/// A thin SwiftUI shell over `PulsarTraceMenuBar`'s ViewModels — no logic
/// lives here. It is a `MenuBarExtra` app: an accessory-policy process with no
/// Dock icon, plus two on-demand `Window` scenes (the unified app window and
/// the live-transcript window) opened from the menu.
@main
struct PulsarTraceMacApp: App {

    /// The shared app environment — the ViewModels every scene binds to.
    /// Owned by `PulsarTraceMenuBar`; this target only renders it.
    @State private var environment: AppEnvironment

    /// The NSEvent global-hotkey monitor — the AppKit piece that stays in
    /// this target (D27); `AppEnvironment` itself is AppKit-free.
    @State private var hotkey: HotkeyController

    init() {
        // No Dock icon, no app-switcher entry — PulsarTrace lives in the
        // menubar (D27). Set in code; there is no `.app` bundle yet.
        //
        // `NSApplication.shared` — not the `NSApp` global — because `App.init()`
        // runs before SwiftUI has created the application object: `NSApp` is
        // still `nil` here and force-unwrapping it crashes. `.shared` creates
        // the instance on first access (and is the same object SwiftUI adopts).
        NSApplication.shared.setActivationPolicy(.accessory)

        let environment = AppEnvironment()
        let hotkey = HotkeyController()
        // Installed here — where `AppEnvironment.init` used to call
        // `installHotkeyMonitor()` — so the hotkey is live from launch.
        hotkey.install(
            settings: environment.settings, recording: environment.recording)
        _environment = State(initialValue: environment)
        _hotkey = State(initialValue: hotkey)
    }

    var body: some Scene {
        // The menubar dropdown — a SwiftUI panel (`.window` style), the style
        // the app has always shipped with. `MenuRowButtonStyle` restyles its
        // rows to read as a native-looking dropdown list (#2).
        MenuBarExtra {
            MenuBarMenuView()
                .environment(environment.recording)
                .environment(environment.queueVM)
                .environment(environment.navigation)
                // The dropdown reads `settings.globalHotkey` to show the
                // shortcut hint next to Start/Stop Recording.
                .environment(environment.settings)
                // R41: re-install the global-hotkey monitor whenever the
                // combo changes in Settings (`install` removes the prior
                // monitor first). The popover content isn't mounted until
                // its first open, so the main window carries a parallel
                // onChange — between them every change re-installs.
                .onChange(of: environment.settings.globalHotkey) {
                    hotkey.install(
                        settings: environment.settings,
                        recording: environment.recording)
                }
        } label: {
            MenuBarLabel(
                status: environment.recording.status,
                isRefining: environment.queueVM.running != nil)
        }
        .menuBarExtraStyle(.window)

        // The unified app window — Recordings / Speakers / Settings sidebar
        // (#6). Replaces the inline panel pages and the standalone `Settings`
        // scene; "Settings…" in the menu opens this window's Settings pane.
        Window("PulsarTrace", id: WindowID.main) {
            MainWindowView(events: environment.events)
                .environment(environment.settings)
                .environment(environment.recording)
                .environment(environment.scanner)
                .environment(environment.navigation)
                .environment(environment.queueVM)
                // Recordings master-detail split (§4): the pane list model,
                // the transcript detail model, and the live watcher the
                // detail binds to for the in-progress recording.
                .environment(environment.paneModel)
                .environment(environment.detailModel)
                .environment(environment.liveWatcher)
                // Parallel to the MenuBarExtra onChange: the recorder lives
                // in this window's Settings pane, and the popover content
                // may never have been mounted when the combo changes here.
                .onChange(of: environment.settings.globalHotkey) {
                    hotkey.install(
                        settings: environment.settings,
                        recording: environment.recording)
                }
        }
        .defaultSize(width: 900, height: 560)

        // The detached live-transcript window (#5) — stays visible
        // independently of the menubar panel.
        Window("Live Transcript", id: WindowID.liveTranscript) {
            LiveTranscriptView()
                .environment(environment.liveWatcher)
        }
        .defaultSize(width: 460, height: 480)
    }
}

/// The menubar icon, a pure function of recording status + refine activity —
/// the three states R40 requires to be distinct at a glance: idle, recording
/// (red waveform + live elapsed timer), and refining (pulsing sync symbol).
private struct MenuBarLabel: View {
    let status: RecordingStatus
    let isRefining: Bool

    var body: some View {
        switch status {
        case .recording(_, let startedAt):
            // Red waveform + elapsed time — unambiguous "live" state (R40).
            // MenuBarExtra labels are template-rendered, so the red tint may
            // be flattened to monochrome; the timer is the primary signal.
            // The TimelineView ticks at 1 Hz for the whole recording (the
            // menubar never goes offscreen) — measured cost is negligible,
            // but it's a continuous timer, not throttled.
            HStack(spacing: 3) {
                Image(systemName: "waveform.badge.microphone")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.red, Color.primary)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedTimeString(from: startedAt, to: context.date))
                        .font(.system(.body, design: .monospaced))
                }
            }
            .accessibilityLabel("PulsarTrace, recording")
        case .launching:
            Image(systemName: "waveform.badge.plus")
                .accessibilityLabel("PulsarTrace, starting recording")
        case .crashed, .error:
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel("PulsarTrace, needs attention")
        case .idle:
            Image(systemName: isRefining ? "arrow.triangle.2.circlepath" : "waveform")
                .symbolEffect(.pulse, isActive: isRefining)
                .accessibilityLabel(isRefining
                    ? "PulsarTrace, refining a transcript"
                    : "PulsarTrace, idle")
        }
    }
}
