import AppKit
import PulsarTraceMenuBar

/// Owns the passive global-hotkey monitor (R41) — the one AppKit dependency
/// the app environment used to carry. `addGlobalMonitorForEvents` needs NO
/// Accessibility TCC grant; the keypress also reaching the frontmost app is
/// an accepted v1 tradeoff (D27). NOT a `CGEventTap`.
///
/// Lives in the app target so `AppEnvironment` (now in `PulsarTraceMenuBar`)
/// stays free of AppKit. `PulsarTraceMacApp` creates one and calls
/// `install(settings:recording:)` at startup — where `AppEnvironment.init`
/// used to call `installHotkeyMonitor()`.
@MainActor
final class HotkeyController {

    /// The installed NSEvent monitor, if any.
    private var monitor: Any?

    /// The in-flight hotkey toggle. A new trigger is dropped while one is
    /// running so a rapid double-press cannot stack `start`/`stop` calls.
    private var toggleTask: Task<Void, Never>?

    /// Install (or reinstall) the passive global hotkey monitor.
    func install(settings: MenuBarSettings, recording: RecordingViewModel) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard let combo = settings.globalHotkey else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
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
            guard self.toggleTask == nil else { return }
            self.toggleTask = Task { [weak self] in
                await Self.toggleRecording(recording)
                self?.toggleTask = nil
            }
        }
    }

    /// Start or stop recording — the hotkey's effect (R41).
    ///
    /// Pause/resume of the refinement queue is owned by `RecordingViewModel`
    /// via the injected hooks, so every path (hotkey, menubar dropdown) is
    /// correct by construction.
    private static func toggleRecording(_ recording: RecordingViewModel) async {
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
