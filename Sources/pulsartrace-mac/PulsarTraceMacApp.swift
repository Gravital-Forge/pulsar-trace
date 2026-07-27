import AppKit
import PulsarTraceMenuBar
import SwiftUI

/// PulsarTrace's menubar app (PT-P2-D9).
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
    /// this target (PT-P2-D9); `AppEnvironment` itself is AppKit-free.
    @State private var hotkey: HotkeyController

    /// Owns the opt-in MCP server lifecycle (PT-R115). Lives here in the
    /// composition root — the only target allowed to import both
    /// `PulsarTraceMenuBar` and `PulsarTraceMCP` — and reconciles the server
    /// against `settings.mcpServerEnabled` / `mcpServerPort`.
    @State private var mcpController: MCPController

    init() {
        // No Dock icon, no app-switcher entry — PulsarTrace lives in the
        // menubar (PT-P2-D9). Set in code; there is no `.app` bundle yet.
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
        // PT-R115: the controller reads the (default-off) toggle and only
        // starts the server when the user enables it in Settings. It takes the
        // whole environment so it can host the toolset over the single shared
        // SpeakerLibrary (PT-P6-D1).
        _mcpController = State(initialValue: MCPController(environment: environment))
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
                // PT-R41: re-install the global-hotkey monitor whenever the
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

        // Both windows opt OUT of macOS state restoration (the
        // `WindowRestorationOptOut` background inside each content view), so
        // the app launches quietly with just its menubar item. Restoration
        // orders a saved window frontmost while launching, but an accessory
        // app is not activated at launch, and cooperative activation
        // (macOS 14+) declines a self-issued `NSApp.activate()` that no
        // user interaction backs — Apple DTS documents this "incomplete
        // activation" state with no app-side workaround (FB21087054
        // family). The restored window therefore drew in the greyed
        // inactive appearance (QA rounds 4–7). With restoration off, every
        // window-open goes through a user action (dropdown click), which
        // carries the intent that makes activation succeed.
        // (`restorationBehavior(.disabled)` is this exact switch as a scene
        // modifier, but it needs macOS 15 and `SceneBuilder` cannot branch
        // on `#available` — the minimum supported OS is macOS 14, so the opt-out is
        // applied at the AppKit level instead.)
        mainWindow
        liveTranscriptWindow
    }

    // The unified app window — Recordings / Speakers / Settings sidebar
    // (#6). Replaces the inline panel pages and the standalone `Settings`
    // scene; "Settings…" in the menu opens this window's Settings pane.
    private var mainWindow: some Scene {
        Window("PulsarTrace", id: WindowID.main) {
            MainWindowView(events: environment.events)
                .environment(environment.settings)
                .environment(environment.recording)
                .environment(environment.scanner)
                .environment(environment.navigation)
                .environment(environment.queueVM)
                // The speaker editor reads the shared SpeakerLibrary off the
                // environment (PT-P6-D1) — the single writer the MCP server uses.
                .environment(environment)
                // Recordings master-detail split (§4): the pane list model,
                // the transcript detail model, and the live watcher the
                // detail binds to for the in-progress recording.
                .environment(environment.paneModel)
                .environment(environment.detailModel)
                .environment(environment.liveWatcher)
                // The MCP Settings section (PT-R115, PT-R125) reads the
                // controller from the environment; the Settings pane lives in
                // this window.
                .environment(mcpController)
                // Parallel to the MenuBarExtra onChange: the recorder lives
                // in this window's Settings pane, and the popover content
                // may never have been mounted when the combo changes here.
                .onChange(of: environment.settings.globalHotkey) {
                    hotkey.install(
                        settings: environment.settings,
                        recording: environment.recording)
                }
        }
        .defaultSize(width: 1104, height: 736)
    }

    // The detached live-transcript window (#5) — stays visible
    // independently of the menubar panel.
    private var liveTranscriptWindow: some Scene {
        Window("Live Transcript", id: WindowID.liveTranscript) {
            LiveTranscriptView()
                .environment(environment.liveWatcher)
        }
        .defaultSize(width: 460, height: 480)
    }
}

/// The menubar icon, a pure function of recording status + refine activity —
/// the three states PT-R40 requires to be distinct at a glance: idle, recording
/// (the waveform with a red dot badge), and refining (pulsing sync symbol).
private struct MenuBarLabel: View {
    let status: RecordingStatus
    let isRefining: Bool

    var body: some View {
        switch status {
        case .recording:
            // The app's normal waveform glyph with a red dot badged at its
            // bottom-right corner — unambiguous "live" state (PT-R40) that keeps
            // the icon recognizable (QA round 5: the tiny microphone in
            // `waveform.badge.microphone` was too small to read). MenuBarExtra
            // labels are template-rendered, so the red may be flattened to
            // monochrome — the dot still reads as a badge either way.
            // Deliberately NO ticking timer here: a
            // `TimelineView(.periodic)` in a status-item label degenerated
            // into a continuous `MenuBarExtraHost.requestUpdate` →
            // `NSStatusBarButton.setImage` → SF-symbol re-resolution loop on
            // macOS 26.5 — 93% of the main thread, a frozen dropdown, and a
            // `cpu_resource` violation while the engine recorded happily
            // (incident 2026-06-11, diagnosed from the .diag stack). The
            // dropdown's status row shows the start time, and the window
            // toolbar carries the ticking elapsed timer — ordinary windows
            // tick safely.
            // `symbolEffect(.pulse)` below survived the same week unscathed,
            // so the ban is on TimelineView/animated text in THIS label, not
            // on symbol effects.
            Image(systemName: "waveform")
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        // Nudge into the corner so the dot reads as a badge
                        // on the icon, not a part of the waveform.
                        .offset(x: 2, y: 2)
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
