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
        } label: {
            Image(systemName: environment.recording.status.menuBarSymbol)
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
        }
        .defaultSize(width: 760, height: 480)

        // The detached live-transcript window (#5) — stays visible
        // independently of the menubar panel.
        Window("Live Transcript", id: WindowID.liveTranscript) {
            LiveTranscriptView()
                .environment(environment.liveWatcher)
        }
        .defaultSize(width: 460, height: 480)
    }
}

extension RecordingStatus {
    /// SF Symbol for the menubar icon, driven by the recording state.
    var menuBarSymbol: String {
        switch self {
        case .idle: return "waveform"
        case .launching: return "waveform.badge.plus"
        case .recording: return "waveform.badge.microphone"
        case .crashed: return "exclamationmark.triangle"
        case .error: return "exclamationmark.triangle"
        }
    }
}
