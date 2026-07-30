// Sources/PulsarTraceMenuBar/AppEnvironment.swift
import Foundation
import Logging
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

    /// Recordings-pane list model (§4.1) — process-lifetime so the selection
    /// and filter survive window churn.
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

    /// The single shared `SpeakerLibrary` writer (PT-P6-D1). Opened during
    /// `bootstrap()` and shared by BOTH the menubar speaker editor and the MCP
    /// server — two actors over the one SQLite file would hold separate caches
    /// and drift, so there is exactly one in-process writer. `nil` until
    /// bootstrap opens it (or if the open fails). Read through
    /// `sharedSpeakerLibrary()`, which awaits bootstrap.
    public private(set) var speakerLibrary: SpeakerLibrary?

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

        self.recording = RecordingViewModel(
            settings: settings, paths: paths, events: events,
            enqueueAutoRefine: { url, recordingId in
                // Waits for bootstrap (the handle's awaitReady) — a stop-
                // recording that lands during bootstrap still gets enqueued.
                await queueHandle.enqueueAutoRefine(
                    folderURL: url, recordingId: recordingId)
            },
            pauseRefinement: { await queueHandle.pauseForRecording() },
            resumeRefinement: { await queueHandle.resumeAfterRecording() })
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

        // Open the single shared speaker library (PT-P6-D1) so the menubar
        // editor and the MCP server both write through one instance. Opened
        // with `events: events` exactly as the editor's own open used to be, so
        // its event behaviour is unchanged. A failure leaves it `nil`; the
        // editor surfaces an error state and the MCP server declines to start.
        self.speakerLibrary = try? await SpeakerLibrary(
            databaseURL: paths.speakersDatabaseURL, events: events)

        // Mirror the live path's language allow-list into refinement
        // (R-streaming-lang). Without this, refinement decoded each region
        // with unrestricted auto-detect, so a quiet/ambiguous stretch in a
        // Polish meeting could drift to Spanish or Russian even when the
        // user had restricted the language set in Settings.
        let refineOptions = TranscriptionOptions(
            allowedLanguages: settings.allowedLanguages)
        let q = await RefinementJobQueue.makeStandard(
            events: events,
            paths: paths,
            options: refineOptions)
        await queueVM.setQueue(q)
        queueVM.onJobsTerminated = { [weak self] jobs in
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
        // change polling only ran while the (since-deleted) Refinements pane
        // was visible, so those two surfaces were stale.
        queueVM.startPolling()
        // Open the handle last — a pre-bootstrap enqueue that resumes here
        // must see the fully wired queue + polling VM.
        queueHandle.install(q)
    }

    /// Await the single shared speaker library (PT-P6-D1), waiting for bootstrap
    /// to finish opening it. Returns `nil` only if the open failed. Both the
    /// menubar editor and the MCP controller resolve the library through this so
    /// they never race ahead of bootstrap or open a second writer.
    public func sharedSpeakerLibrary() async -> SpeakerLibrary? {
        await bootstrapTask?.value
        return speakerLibrary
    }

    /// The owner voice profile store (PT-P8-R6), at the standard path beside the
    /// speaker library. Built on demand — it is a stateless file-backed actor
    /// (its own cache), so a fresh instance reads the same `owner-profile.json`.
    /// The speaker editor passes this into `SpeakerEditService` so owner
    /// reassignment ("this is me" / "not me") updates the profile.
    public func ownerProfileStore() -> OwnerVoiceProfileStore {
        OwnerVoiceProfileStore(fileURL: paths.ownerProfileURL)
    }

    /// PT-P8-R3 (d) / PT-P8-R12 — the sticky mic-diarization toggle changed.
    /// On the first false→true transition, if no owner profile exists yet,
    /// backfill it once in the background from existing (never-diarized)
    /// recordings so live "You" works immediately. A profile already present
    /// ⇒ no backfill; the toggle turning off ⇒ nothing to do here.
    ///
    /// The app's composition-root scene observes `settings.diarizeMicEnabled`
    /// and calls this (never the Settings view — a CLI-less launch that flips
    /// the stored default must still backfill). If a refine job is running the
    /// backfill's diarizer competes for the ANE; the queue's PauseGate does not
    /// govern this ad-hoc work — accepted for now (close-out follow-up).
    public func diarizeMicToggled(_ enabled: Bool) {
        guard enabled else { return }
        let ownerURL = paths.ownerProfileURL
        // Same roots the recordings pane scans: current + previously-used
        // output folders, de-duplicated.
        var roots = [settings.outputFolderURL].compactMap { $0 }
        roots += settings.previousFolderURLs
        var seen = Set<String>()
        let outputRoots = roots.filter { seen.insert($0.path).inserted }
        let events = self.events
        let modelsCacheRoot = paths.modelsCacheDirectory
        Task.detached(priority: .utility) {
            let store = OwnerVoiceProfileStore(fileURL: ownerURL)
            guard await store.snapshot() == nil else { return }
            let logger = Logger(label: LogSubsystem.engine)
            let diarizer = Diarizer(
                configuration: .init(cacheRoot: modelsCacheRoot),
                logger: logger)
            let summary = try? await OwnerProfileBackfill.run(
                outputRoots: outputRoots,
                store: store,
                diarize: { try await diarizer.diarizeStream(wavPath: $0) },
                events: events,
                logger: logger)
            if let summary {
                logger.notice(
                    "owner-profile backfill: scanned \(summary.foldersScanned), accepted \(summary.samplesAccepted)")
            }
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
}
