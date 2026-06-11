// Sources/PulsarTraceMenuBar/AppEnvironment.swift
import Foundation
import PulsarTraceEngine
import UserNotifications

/// Owns the app's long-lived ViewModels and their bootstrap wiring.
///
/// Lives in `PulsarTraceMenuBar` (the testable, SwiftUI-free target) so the
/// view layer in `pulsartrace-mac` only binds to it — the views never
/// construct engine objects themselves. AppKit concerns (the NSEvent global
/// hotkey monitor) stay in the app target (`HotkeyController`).
@MainActor
@Observable
public final class AppEnvironment {
    public let settings: MenuBarSettings
    public let recording: RecordingViewModel
    public let scanner: RecordingsScanner
    public let liveWatcher: LiveTranscriptWatcher
    public let onboarding: OnboardingTourViewModel

    /// Recordings-pane list model (§4.1) — process-lifetime so the selection,
    /// filter, and just-refined acknowledgments survive window churn.
    public let paneModel: RecordingsPaneModel

    /// Transcript detail model (§4.2).
    public let detailModel: TranscriptDetailModel

    /// Shared sidebar-navigation state for the unified window (#6). Assigned
    /// explicitly in `init()` (not inline) so `paneModel` can be constructed
    /// with it while all stored properties are still being initialized.
    public let navigation: AppNavigation

    /// The process-wide events writer (§8.13). Bootstrapped here and shared by
    /// every component that emits events — the re-refine pass and the speaker
    /// editor — so the events-log public contract holds in the shipped app.
    public let events: EventWriter

    /// The standard app paths — events directory, speaker library, sockets.
    private let paths: AppPaths

    /// The recording flow's seam onto the not-yet-built refinement queue.
    /// Created FIRST in `init()` so `RecordingViewModel`'s closures can
    /// reference it directly (no `self` capture before full initialization);
    /// `bootstrap()` installs the real queue into it.
    private let queueHandle: RefinementQueueHandle

    /// Main-actor façade over the refinement queue — always non-optional (E2).
    /// Initialised with a placeholder (noop) queue in `init()`; `bootstrap()`
    /// swaps in the real queue via `setQueue(_:)` once `makeStandard`
    /// completes. Non-optional so it can be passed directly to
    /// `.environment(...)` without extra wrappers.
    public let queueVM: RefinementJobQueueViewModel

    /// Observes `recording.liveMarkdownURL` and points the `LiveTranscriptWatcher`
    /// at it — so the live popover shows the real, growing transcript whether
    /// or not it is open (FIX 1). Lives for the process lifetime.
    private var liveWatcherWiring: Task<Void, Never>?

    /// Handle for the combined bootstrap task (events → queue). Stored so
    /// it can be cancelled if `AppEnvironment` is ever torn down.
    private var bootstrapTask: Task<Void, Never>?

    public init() {
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

        // The handle breaks the init-order cycle: RecordingViewModel's
        // closures need the refinement queue, but the queue is built
        // asynchronously in bootstrap() and `recording` is itself a stored
        // property — so the closures cannot capture `self`. They capture this
        // pre-created handle instead; bootstrap() installs the real queue.
        let queueHandle = RefinementQueueHandle(settings: settings)
        self.queueHandle = queueHandle

        // Phase 6 / Layer B: probe the binary-level `whisper.lock` between
        // pauseRefinement and the orchestrator's start. `pauseRefinement`
        // terminates the refinement-whisper subprocess (Layer A); this
        // probe is the defence-in-depth that catches the rare slow-teardown
        // window before the engine subprocess hits the flock.
        let lockProbePath = paths.applicationSupport
            .appendingPathComponent("whisper.lock", isDirectory: false)
        self.recording = RecordingViewModel(
            settings: settings, paths: paths, events: events,
            enqueueAutoRefine: { url, recordingId in
                // Waits for bootstrap (the handle's awaitReady) — a stop-
                // recording that lands during bootstrap still gets enqueued.
                await queueHandle.enqueueAutoRefine(
                    folderURL: url, recordingId: recordingId)
            },
            pauseRefinement: { await queueHandle.pauseForRecording() },
            resumeRefinement: { await queueHandle.resumeAfterRecording() },
            waitForWhisperLockFree: {
                try await WhisperLockProbe.waitUntilFree(
                    lockPath: lockProbePath,
                    timeout: .seconds(5))
            })
        let scanner = RecordingsScanner(settings: settings)
        let liveWatcher = LiveTranscriptWatcher()
        let navigation = AppNavigation()
        self.scanner = scanner
        self.liveWatcher = liveWatcher
        self.navigation = navigation
        self.onboarding = OnboardingTourViewModel()

        // §4.1 / §4.2 view models. Built from the locals above purely for
        // symmetry with their assignments — already-assigned stored
        // properties (like `self.recording` here) are fine to read mid-init.
        self.paneModel = RecordingsPaneModel(
            scanner: scanner, queueVM: queueVM,
            recording: self.recording, navigation: navigation)
        self.detailModel = TranscriptDetailModel(
            queueVM: queueVM, liveWatcher: liveWatcher)

        // Chain events bootstrap → queue bootstrap in a single stored Task so
        // that `RefinementJobQueue.makeStandard` (and any `runJob` it spawns)
        // always sees a fully bootstrapped events writer. The handle is stored
        // so cancellation is possible if `AppEnvironment` is ever torn down.
        self.bootstrapTask = Task { [weak self] in
            await events.bootstrap()
            await self?.bootstrap()
        }
        startLiveWatcherWiring()
    }

    /// Build the refinement queue asynchronously. Invoked from a fire-and-forget
    /// `Task` in `init()` — the same pattern as `events.bootstrap()`. Keeps
    /// `init()` synchronous while allowing the expensive async setup to run
    /// once the MainActor is free after initialization.
    private func bootstrap() async {
        // Wire `swift-log` into the daily-rotated `FileLogHandler` and
        // `OSLogHandler` — the *engine subprocess* bootstraps these via
        // `AppLifecycle.start()`, but the mac-app process never calls
        // `AppLifecycle`. Without this call the in-process refinement
        // queue's `Logger(label: LogSubsystem.engine)` lines fell into
        // swift-log's default `StreamLogHandler` (stderr → launchd),
        // making refinement failures undebuggable from `~/Library/Logs/
        // PulsarTrace/*.log` (verified empty for the 2026-05-27 incident).
        // `LogSystem.bootstrap` is idempotent — see
        // `LoggingTests.bootstrapIsIdempotent`.
        _ = await LogSystem.bootstrap(paths: paths)

        // Resolve the whisper binary once, from the mac-app's known
        // `.build/debug/...` layout (via `#filePath`). The same resolver is
        // threaded into the engine subprocess as `PULSARTRACE_WHISPER_BINARY`
        // by `defaultOrchestratorFactory`, so refinement and live decode
        // share a single source of truth for the binary path — and the
        // resolver's `argv[0]`-sibling fallback never gets a chance to
        // silently mis-locate it in the mac-app process.
        let whisperBinaryURL =
            RecordingViewModel.defaultBinaryURLResolver("pulsartrace-whisper")
        // Mirror the live path's language allow-list into refinement
        // (R-streaming-lang). Without this, refinement decoded each region
        // with unrestricted auto-detect, so a quiet/ambiguous stretch in a
        // Polish meeting could drift to Spanish or Russian even when the
        // user had restricted the language set in Settings.
        let refineWhisperOptions = WhisperOptions(
            allowedLanguages: settings.allowedLanguages)
        let q = await RefinementJobQueue.makeStandard(
            events: events,
            whisperBinaryURL: whisperBinaryURL,
            paths: paths,
            whisperOptions: refineWhisperOptions)
        await queueVM.setQueue(q)
        queueVM.onJobsTerminated = { [weak self] jobs in
            self?.paneModel.noteJobsTerminated(jobs)
            self?.detailModel.noteJobsTerminated(jobs)
            Task { [weak self] in await self?.scanner.refresh() }
            // Bare-binary dev runs (`.build/debug/pulsartrace-mac`) have no
            // bundle — UN APIs crash in non-bundled processes.
            guard Bundle.main.bundleIdentifier != nil else { return }
            for job in jobs {
                guard let content = RefinementNotification.from(job: job) else { continue }
                let c = UNMutableNotificationContent()
                c.title = content.title
                c.body = content.body
                // recordingId as the identifier: a re-refine of the same
                // recording REPLACES the stale notification instead of
                // stacking a second one.
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: job.recordingId, content: c, trigger: nil))
            }
        }
        // Provisional auth: delivers quietly to Notification Center without a
        // permission dialog. Same bundle guard — crashes in bare dev runs.
        if Bundle.main.bundleIdentifier != nil {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .provisional])
        }
        // Single process-wide poller. The menubar dropdown and the
        // recordings-list RefineBadge both read from queueVM; before this
        // change polling only ran while RefinementsListView was visible,
        // so those two surfaces were stale.
        queueVM.startPolling()
        // Open the handle last — a pre-bootstrap enqueue that resumes here
        // must see the fully wired queue + polling VM.
        queueHandle.install(q)
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
}
