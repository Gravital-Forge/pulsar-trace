import AppKit
import PulsarTraceEngine
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
    @State private var environment = AppEnvironment()

    init() {
        // No Dock icon, no app-switcher entry — PulsarTrace lives in the
        // menubar (D27). Set in code; there is no `.app` bundle yet.
        //
        // `NSApplication.shared` — not the `NSApp` global — because `App.init()`
        // runs before SwiftUI has created the application object: `NSApp` is
        // still `nil` here and force-unwrapping it crashes. `.shared` creates
        // the instance on first access (and is the same object SwiftUI adopts).
        NSApplication.shared.setActivationPolicy(.accessory)
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

/// A mutable container for an async closure — used to break the init-time
/// dependency cycle in `AppEnvironment`. `RecordingViewModel` calls `call(_:_:)`
/// on the box; `AppEnvironment` wires the real implementation into `impl` once
/// `self` is fully initialized (every stored property is set).
///
/// `@unchecked Sendable` because `impl` is mutated once during init on the
/// MainActor and read-only thereafter — the mutation happens before any
/// concurrent caller can reach it.
private final class EnqueueBox: @unchecked Sendable {
    var impl: (@Sendable (URL, String) async -> Void)?

    func call(_ url: URL, _ recordingId: String) async {
        await impl?(url, recordingId)
    }
}

/// A mutable container for a no-argument async closure — same init-time
/// dependency-cycle break as `EnqueueBox`, used for `pauseRefinement` and
/// `resumeRefinement`.
///
/// `@unchecked Sendable`: mutated once during init on the MainActor, then
/// read-only from `RecordingViewModel` closures.
private final class AsyncCallBox: @unchecked Sendable {
    var impl: (@Sendable () async -> Void)?

    func call() async {
        await impl?()
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

    /// Shared sidebar-navigation state for the unified window (#6).
    let navigation = AppNavigation()

    /// The process-wide events writer (§8.13). Bootstrapped here and shared by
    /// every component that emits events — the re-refine pass and the speaker
    /// editor — so the events-log public contract holds in the shipped app.
    let events: EventWriter

    /// The standard app paths — events directory, speaker library, sockets.
    let paths: AppPaths

    /// The single-worker refinement queue (D2). Built asynchronously in
    /// `bootstrap()` — `nil` until then, so `toggleRecording` uses optional
    /// calls throughout. This matches the existing `events.bootstrap()` pattern:
    /// async setup is deferred to an `App.task { }`, keeping `init()` sync.
    private(set) var queue: RefinementJobQueue? = nil

    /// Main-actor façade over `queue` — always non-optional (E2). Initialised
    /// with a placeholder (noop) queue in `init()`; `bootstrap()` swaps in the
    /// real queue via `setQueue(_:)` once `makeStandard` completes. Non-optional
    /// so it can be passed directly to `.environment(...)` without extra wrappers.
    let queueVM: RefinementJobQueueViewModel

    /// Passive global-hotkey monitor (R41). `addGlobalMonitorForEvents` needs
    /// NO Accessibility TCC grant; the keypress also reaching the frontmost
    /// app is an accepted v1 tradeoff (D27). NOT a `CGEventTap`.
    private var hotkeyMonitor: Any?

    /// The in-flight hotkey toggle. A new trigger is dropped while one is
    /// running so a rapid double-press cannot stack `start`/`stop` calls.
    private var hotkeyToggleTask: Task<Void, Never>?

    /// Observes `recording.liveMarkdownURL` and points the `LiveTranscriptWatcher`
    /// at it — so the live popover shows the real, growing transcript whether
    /// or not it is open (FIX 1). Lives for the process lifetime.
    private var liveWatcherWiring: Task<Void, Never>?

    /// Handle for the combined bootstrap task (events → queue). Stored so
    /// it can be cancelled if `AppEnvironment` is ever torn down.
    private var bootstrapTask: Task<Void, Never>?

    init() {
        let settings = MenuBarSettings()
        let paths = AppPaths.standard
        let events = EventWriter(directory: paths.eventsDirectory)
        self.settings = settings
        self.paths = paths
        self.events = events

        // Placeholder queue used only to make queueVM non-Optional before
        // bootstrap() swaps in the real queue. Points at a unique temp dir so
        // it can never accidentally read or write the real refinement-queue
        // store on disk.
        let placeholderDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsartrace-placeholder-queue-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        let placeholderStore = RefinementJobStore(directory: placeholderDir)
        let placeholderQueue = RefinementJobQueue(
            store: placeholderStore, runJob: { _ in })
        self.queueVM = RefinementJobQueueViewModel(queue: placeholderQueue)

        // Indirection boxes: let RecordingViewModel call real closures before
        // `self` is fully initialized (Swift forbids [weak self] captures until
        // every stored property is set, which `recording` itself prevents). Each
        // box is created up-front, passed into RecordingViewModel as the closure
        // payload, and filled in below once `self` is complete.
        let enqueueBox = EnqueueBox()
        let pauseBox = AsyncCallBox()
        let resumeBox = AsyncCallBox()

        self.recording = RecordingViewModel(
            settings: settings, paths: paths, events: events,
            enqueueAutoRefine: { url, recordingId in
                await enqueueBox.call(url, recordingId)
            },
            pauseRefinement: { await pauseBox.call() },
            resumeRefinement: { await resumeBox.call() })
        self.scanner = RecordingsScanner(settings: settings)
        self.liveWatcher = LiveTranscriptWatcher()
        self.onboarding = OnboardingTourViewModel()

        // All stored properties are now set — `self` is fully initialized.
        // Wire the real implementations into the boxes. Closures hop to MainActor
        // to read @MainActor-isolated state before crossing into the queue actor.
        enqueueBox.impl = { [weak self] url, recordingId in
            let pair: (RefinementJobQueue, String, String)? =
                await MainActor.run {
                    guard let self, let queue = self.queue else { return nil }
                    let name = self.settings.refineModelName
                    let model = ModelCatalog.model(named: name) ?? ModelCatalog.base
                    return (queue, model.name, model.sha256)
                }
            guard let (queue, modelName, modelSHA256) = pair else {
                // Bootstrap race window — covered properly by Task 9. For
                // now: explicit log instead of a silent drop so the gap is
                // visible until Task 9 closes it.
                FileHandle.standardError.write(
                    Data("pulsartrace-mac: auto-refine dropped — queue not yet ready\n".utf8))
                return
            }
            do {
                try await queue.enqueueAutoRefine(
                    folderURL: url, recordingId: recordingId,
                    modelName: modelName, modelSHA256: modelSHA256)
            } catch {
                let msg = "pulsartrace-mac: auto-refine enqueue failed: \(error)\n"
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~")
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }
        pauseBox.impl = { [weak self] in
            let q: RefinementJobQueue? = await MainActor.run { self?.queue }
            await q?.pauseForRecording()
        }
        resumeBox.impl = { [weak self] in
            let q: RefinementJobQueue? = await MainActor.run { self?.queue }
            await q?.resumeAfterRecording()
        }

        // Chain events bootstrap → queue bootstrap in a single stored Task so
        // that `RefinementJobQueue.makeStandard` (and any `runJob` it spawns)
        // always sees a fully bootstrapped events writer. The handle is stored
        // so cancellation is possible if `AppEnvironment` is ever torn down.
        self.bootstrapTask = Task { [weak self] in
            await events.bootstrap()
            await self?.bootstrap()
        }
        installHotkeyMonitor()
        startLiveWatcherWiring()
    }

    /// Build the refinement queue asynchronously. Invoked from a fire-and-forget
    /// `Task` in `init()` — the same pattern as `events.bootstrap()`. Keeps
    /// `init()` synchronous while allowing the expensive async setup to run
    /// once the MainActor is free after initialization.
    func bootstrap() async {
        let q = await RefinementJobQueue.makeStandard(events: events, paths: paths)
        self.queue = q
        await queueVM.setQueue(q)
        queueVM.onJobTerminated = { [weak self] _ in
            guard let self else { return }
            Task { await self.scanner.refresh() }
        }
    }

    /// Drive the `LiveTranscriptWatcher` off `recording.liveMarkdownURL` (FIX 1).
    ///
    /// The watcher was created but never `start()`-ed at a file, so the live
    /// popover showed "Waiting for transcript" forever. This observes the VM's
    /// `liveMarkdownURL`: when a recording begins the watcher tails that real
    /// `live.md`; when it ends the watcher is stopped. The wiring lives at the
    /// app level so the watcher keeps tailing whether or not the popover is
    /// open — re-opening the popover just re-reads the already-tailed lines.
    private func startLiveWatcherWiring() {
        liveWatcherWiring = Task { @MainActor [weak self] in
            var current: URL?
            while !Task.isCancelled {
                guard let self else { return }
                let url = self.recording.liveMarkdownURL
                if url != current {
                    current = url
                    if let url {
                        self.liveWatcher.start(liveMarkdownURL: url)
                    } else {
                        self.liveWatcher.stop()
                    }
                }
                // `liveMarkdownURL` flips at most twice per session (recording
                // start / stop), so a light poll is ample — no `withObservation`
                // plumbing needed. `@MainActor` so the VM read is in-isolation.
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
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
    ///
    /// Pause/resume of the refinement queue is now owned by `RecordingViewModel`
    /// via the injected hooks, so every path (hotkey, menubar dropdown) is
    /// correct by construction.
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
        case .crashed: return "exclamationmark.triangle"
        case .error: return "exclamationmark.triangle"
        }
    }
}
