import AppKit
import PulsarTraceEngine
import PulsarTraceMenuBar
import SwiftUI

/// PulsarTrace's menubar app (Epic 8, D27).
///
/// A thin SwiftUI shell over `PulsarTraceMenuBar`'s ViewModels — no logic
/// lives here. It is a `MenuBarExtra` app: an accessory-policy process with no
/// Dock icon and no main window, plus a `Settings` scene.
@main
struct PulsarTraceMacApp: App {

    /// The shared app environment — the ViewModels every scene binds to.
    @State private var environment = AppEnvironment()

    init() {
        // No Dock icon, no app-switcher entry — PulsarTrace lives in the
        // menubar (D27). Set in code; there is no `.app` bundle in Epic 8.
        //
        // `NSApplication.shared` — not the `NSApp` global — because `App.init()`
        // runs before SwiftUI has created the application object: `NSApp` is
        // still `nil` here and force-unwrapping it crashes. `.shared` creates
        // the instance on first access (and is the same object SwiftUI adopts).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView(events: environment.events)
                .environment(environment.settings)
                .environment(environment.recording)
                .environment(environment.scanner)
                .environment(environment.liveWatcher)
        } label: {
            Image(systemName: environment.recording.status.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(environment.settings)
        }
    }
}

/// Owns the long-lived ViewModels + the global-hotkey monitor.
@MainActor
@Observable
final class AppEnvironment {
    let settings: MenuBarSettings
    let recording: RecordingViewModel
    let scanner: RecordingsScanner
    let liveWatcher: LiveTranscriptWatcher
    let onboarding: OnboardingTourViewModel

    /// The process-wide events writer (§8.13). Bootstrapped here and shared by
    /// every component that emits events — the re-refine pass and the speaker
    /// editor — so the events-log public contract holds in the shipped app.
    let events: EventWriter

    /// The standard app paths — events directory, speaker library, sockets.
    let paths: AppPaths

    /// Passive global-hotkey monitor (R41). `addGlobalMonitorForEvents` needs
    /// NO Accessibility TCC grant; the keypress also reaching the frontmost
    /// app is an accepted v1 tradeoff (D27). NOT a `CGEventTap`.
    private var hotkeyMonitor: Any?

    /// The in-flight hotkey toggle. A new trigger is dropped while one is
    /// running so a rapid double-press cannot stack `start`/`stop` calls.
    private var hotkeyToggleTask: Task<Void, Never>?

    init() {
        let settings = MenuBarSettings()
        let paths = AppPaths.standard
        let events = EventWriter(directory: paths.eventsDirectory)
        self.settings = settings
        self.paths = paths
        self.events = events
        self.recording = RecordingViewModel(
            settings: settings, paths: paths, events: events)
        self.scanner = RecordingsScanner(
            settings: settings, paths: paths, events: events)
        self.liveWatcher = LiveTranscriptWatcher()
        self.onboarding = OnboardingTourViewModel()
        // Bootstrap the events writer (creates today's events file) before any
        // component emits — mirrors `AppLifecycle.start`.
        Task { await events.bootstrap() }
        installHotkeyMonitor()
    }

    /// Install (or reinstall) the passive global hotkey monitor.
    func installHotkeyMonitor() {
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            self.hotkeyMonitor = nil
        }
        guard let combo = settings.globalHotkey else { return }
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return }
            // The modifier keys that matter for a shortcut — masks off
            // device-dependent bits (caps lock, fn, numeric pad).
            let relevant: NSEvent.ModifierFlags =
                [.command, .control, .option, .shift]
            let activeModifiers = event.modifierFlags
                .intersection(relevant).rawValue
            guard event.keyCode == combo.keyCode,
                  activeModifiers == combo.modifiers
            else { return }
            // Debounce: ignore the press while a toggle is still in flight so
            // a rapid double-press cannot stack a start on top of a stop.
            guard self.hotkeyToggleTask == nil else { return }
            self.hotkeyToggleTask = Task { [weak self] in
                await self?.toggleRecording()
                self?.hotkeyToggleTask = nil
            }
        }
    }

    /// Start or stop recording — the hotkey's effect (R41).
    func toggleRecording() async {
        switch recording.status {
        case .idle:
            await recording.startRecording()
        case .recording:
            await recording.stopRecording()
        default:
            break
        }
    }
}

extension RecordingStatus {
    /// SF Symbol for the menubar icon, driven by the recording state.
    var menuBarSymbol: String {
        switch self {
        case .idle: return "waveform"
        case .launching: return "waveform.badge.plus"
        case .recording: return "waveform.badge.microphone"
        case .refining: return "waveform.badge.exclamationmark"
        case .crashed: return "exclamationmark.triangle"
        case .error: return "exclamationmark.triangle"
        }
    }
}
