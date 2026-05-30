import Foundation
import PulsarTraceEngine

/// The orchestration seam the `RecordingViewModel` drives (R40, R45).
///
/// `RecordOrchestrator` (an `actor` spawning real subprocesses) is the
/// production conformer; tests inject a stub so the status machine can be
/// exercised without spawning capture/engine processes. The protocol exposes
/// only the four operations the VM needs.
public protocol RecordingOrchestrating: Sendable {
    /// Launch the capture+engine pair; throws on a start failure.
    func start(readyTimeout: Duration) async throws
    /// Suspend until the engine process exits on its own.
    func waitForEngineExit() async
    /// Whether the engine subprocess is still running.
    func isEngineRunning() async -> Bool
    /// Stop the session and tear the subprocess pair down.
    func stop() async
}

/// `RecordOrchestrator` conforms by forwarding — `stop()` discards the
/// `Outcome` the VM does not need. `isEngineRunning()` / `start` /
/// `waitForEngineExit` already match the protocol's signatures (an actor
/// method is `async` when called from outside the actor).
extension RecordOrchestrator: RecordingOrchestrating {
    public func stop() async {
        _ = await stop(engineGrace: .seconds(60))
    }
}

/// Drives one menubar recording session: start → record → idle, with crash
/// detection (R40, R45). Post-recording refinement is enqueued onto the
/// `RefinementJobQueue` via the injected `enqueueAutoRefine` closure and runs
/// asynchronously — the recording state machine returns to `.idle` immediately,
/// enabling back-to-back meetings without blocking on refine.
///
/// Pause/resume of the refinement queue is owned by this VM (via the injected
/// `pauseRefinement` / `resumeRefinement` hooks) so every start/stop path
/// (menubar dropdown, hotkey, future) is correct by construction.
///
/// `@MainActor @Observable` so the menubar binds to `status` / `progressMessage`
/// directly. Orchestration (process spawning) is behind the
/// `RecordingOrchestrating` seam and `enqueueAutoRefine` so the whole status
/// machine is unit-testable without real audio or subprocesses.
@MainActor
@Observable
public final class RecordingViewModel {

    /// The current recording state — the menubar icon/menu is a function of it.
    public private(set) var status: RecordingStatus = .idle

    /// A short human-readable progress line for the menu (R26-style).
    public private(set) var progressMessage: String = ""

    /// The in-flight recording's `live.md` URL while a recording is running,
    /// `nil` otherwise. Set when a recording starts (capture has begun writing
    /// `live.md`) and cleared when it ends. The `LiveTranscriptWatcher` is
    /// pointed at this URL so the live popover shows the real, growing
    /// transcript (FIX 1) — the watcher was previously never told which file
    /// to tail.
    public private(set) var liveMarkdownURL: URL?

    private let settings: MenuBarSettings
    private let paths: AppPaths
    private let clock: @Sendable () -> Date

    /// Builds an orchestrator for a given `RecordPlan` + binary resolver. The
    /// production factory builds a real `RecordOrchestrator`; tests inject a
    /// factory returning a stub.
    private let orchestratorFactory: @Sendable (RecordPlan, @escaping @Sendable (String) -> URL)
        -> RecordingOrchestrating

    /// Resolves a binary name (`pulsartrace-capture`) to an on-disk URL. The
    /// production default points at `.build/debug/<name>` derived from
    /// `#filePath`; a future change swaps this to `Bundle.main`.
    private let binaryURLResolver: @Sendable (String) -> URL

    /// Enqueues a finished (or partial) recording folder onto the async refine
    /// queue. Receives the folder URL and the `rec_<short>` id. The production
    /// implementation enqueues onto `RefinementJobQueue` (wired in D2); tests
    /// inject a capturing closure or pass `nil` for a no-op default.
    private let enqueueAutoRefine: @Sendable (URL, String) async -> Void

    /// Called immediately before the recording subprocess is started — asks the
    /// `RefinementJobQueue` to yield CPU/I/O to the live pass. Default is a
    /// no-op so unit tests and CLI usage stay simple.
    private let pauseRefinement: @Sendable () async -> Void

    /// Called after the recording stops (or after a start failure) — resumes
    /// the `RefinementJobQueue`. Default is a no-op.
    private let resumeRefinement: @Sendable () async -> Void

    /// Defence-in-depth check between `pauseRefinement` and orchestration
    /// start (Phase 6): waits for the binary-level `whisper.lock` to be free
    /// so the engine's `pulsartrace-whisper` does not race the refinement
    /// subprocess's lock release. Throws on timeout — the VM surfaces that
    /// as a user-facing `.error` and reverts to `.idle`. Default is a no-op
    /// for unit tests + the CLI; the mac-app injects the real probe.
    private let waitForWhisperLockFree: @Sendable () async throws -> Void

    /// The orchestrator for the in-flight session, if any.
    private var orchestrator: RecordingOrchestrating?
    /// The crash-watch task started after a successful `start()`.
    private var crashWatch: Task<Void, Never>?
    /// Output folder of the in-flight recording. Carried so the post-recording
    /// refine targets it directly: a just-recorded folder has no
    /// `metadata.json` yet (that file is written *by* refinement), so it cannot
    /// be re-discovered by scanning the output root.
    private var currentRecordingFolder: URL?

    /// - Parameters:
    ///   - settings: source of the mic, model, output folder, system-audio flag.
    ///   - paths: resolves socket locations (default `.standard`).
    ///   - events: unused — retained for API compatibility; will be removed
    ///     once D2 wires `AppEnvironment` to pass an `enqueueAutoRefine` closure.
    ///   - clock: injectable wall clock (deterministic tests).
    ///   - binaryURLResolver: name → binary URL (default `.build/debug/<name>`).
    ///   - orchestratorFactory: builds the orchestration seam — default builds a
    ///     real `RecordOrchestrator`; tests inject a stub factory.
    ///   - enqueueAutoRefine: called with `(folderURL, recordingId)` after a
    ///     successful stop or crash recovery. Default is a no-op; D2 injects the
    ///     real `RefinementJobQueue.enqueue` closure.
    ///   - pauseRefinement: called before the recording subprocess starts to
    ///     ask the queue to yield resources to the live pass. Default is a no-op.
    ///   - resumeRefinement: called after recording stops or on a start failure.
    ///     Default is a no-op so unit tests and CLI usage stay simple.
    ///   - waitForWhisperLockFree: called between `pauseRefinement` and the
    ///     orchestrator's `start()` to confirm the binary-level
    ///     `whisper.lock` is free (Phase 6 / Layer B). Throws on timeout —
    ///     the VM surfaces a "refinement is still finishing up" `.error`.
    ///     Default is a no-op (unit tests + CLI); the mac-app injects the
    ///     real probe pointing at `paths.applicationSupport/whisper.lock`.
    public init(
        settings: MenuBarSettings,
        paths: AppPaths = .standard,
        events: EventWriter? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        binaryURLResolver: (@Sendable (String) -> URL)? = nil,
        orchestratorFactory: (@Sendable (RecordPlan, @escaping @Sendable (String) -> URL)
            -> RecordingOrchestrating)? = nil,
        enqueueAutoRefine: (@Sendable (URL, String) async -> Void)? = nil,
        pauseRefinement: (@Sendable () async -> Void)? = nil,
        resumeRefinement: (@Sendable () async -> Void)? = nil,
        waitForWhisperLockFree: (@Sendable () async throws -> Void)? = nil
    ) {
        self.settings = settings
        self.paths = paths
        self.clock = clock
        self.binaryURLResolver = binaryURLResolver
            ?? RecordingViewModel.defaultBinaryURLResolver
        self.orchestratorFactory = orchestratorFactory
            ?? RecordingViewModel.defaultOrchestratorFactory
        self.enqueueAutoRefine = enqueueAutoRefine ?? { _, _ in }
        self.pauseRefinement = pauseRefinement ?? {}
        self.resumeRefinement = resumeRefinement ?? {}
        self.waitForWhisperLockFree = waitForWhisperLockFree ?? {}
    }

    // MARK: - Start

    /// Start a recording (R40). A no-op if a recording is not startable from
    /// the current state — a second start while not `.idle` is rejected.
    public func startRecording() async {
        guard status.canStartRecording else { return }
        status = .launching
        progressMessage = "Starting capture…"

        // Resolve the output folder; without one, surface an error.
        guard let outputRoot = settings.outputFolderURL else {
            status = .error(message: "Choose an output folder in Settings first.")
            progressMessage = ""
            return
        }

        let folderName = Self.recordingFolderName(at: clock())
        let outputFolder = outputRoot.appendingPathComponent(
            folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: outputFolder, withIntermediateDirectories: true)
        } catch {
            status = .error(message: "Cannot create the recording folder.")
            progressMessage = ""
            return
        }
        currentRecordingFolder = outputFolder

        let plan = RecordPlan.make(
            outputFolder: outputFolder,
            paths: paths,
            micDeviceID: settings.selectedMicDeviceID,
            systemAudioEnabled: settings.systemAudioEnabled,
            modelName: settings.liveModelName)

        let orchestrator = orchestratorFactory(plan, binaryURLResolver)
        self.orchestrator = orchestrator

        // KNOWN ISSUE (deferred — see the future first-run permissions wizard):
        // starting without TCC mic/system-audio grants races the OS permission
        // prompt — `orchestrator.start` can fail and surface a "permissions
        // not granted" error before the user has finished responding to the
        // prompt. Deliberately left as-is; the first-run wizard will
        // request and confirm grants up front, before the first start.
        await pauseRefinement()

        // Phase 6 / Layer B: defence-in-depth wait for the binary-level
        // `whisper.lock` to actually be free before the engine spawns its
        // own `pulsartrace-whisper`. `pauseRefinement` already terminated
        // the refinement subprocess (Layer A in `RefinementJobQueue`); the
        // probe catches the rare slow-teardown case so we surface a
        // user-readable error instead of the silent "engine subprocess
        // exit 75 → model_load_failed" mode.
        do {
            try await waitForWhisperLockFree()
        } catch {
            self.orchestrator = nil
            await resumeRefinement()
            status = .error(
                message: "Refinement is still finishing up. Try again in a moment.")
            progressMessage = ""
            return
        }

        do {
            try await orchestrator.start(readyTimeout: .seconds(20))
        } catch {
            self.orchestrator = nil
            await resumeRefinement()
            status = .error(message: "Could not start recording: \(error)")
            progressMessage = ""
            return
        }

        let startedAt = clock()
        // Point the live transcript at the engine's `live.md` in this folder
        // (FIX 1). Published before `status` flips so an observer reacting to
        // `.recording` already sees the URL.
        liveMarkdownURL = outputFolder.appendingPathComponent(
            RecordingFolder.FileName.live)
        status = .recording(id: plan.recordingId, startedAt: startedAt)
        progressMessage = "Recording…"

        // Crash watch: if the engine exits while still `.recording`, the live
        // pass died unexpectedly (R45). A normal stop cancels this task before
        // the engine exits, so it does not misfire on the happy path.
        let recordingId = plan.recordingId
        crashWatch = Task { [weak self] in
            await orchestrator.waitForEngineExit()
            // A deliberate `stopRecording()` cancels this task before the
            // engine exits — bail before treating that exit as a crash.
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.handleEngineExit(
                recordingId: recordingId, partialFolder: outputFolder)
        }
    }

    // MARK: - Stop

    /// Stop the in-flight recording and enqueue an auto-refine job (R40).
    ///
    /// Returns to `.idle` immediately after stopping the subprocess pair —
    /// the offline refine pass runs asynchronously on the `RefinementJobQueue`,
    /// so a new recording can be started right away (back-to-back meetings).
    public func stopRecording() async {
        guard case .recording(let id, _) = status,
              let orchestrator else { return }

        // Cancel the crash watch first — a deliberate stop is not a crash.
        crashWatch?.cancel()
        crashWatch = nil

        progressMessage = "Stopping…"
        await orchestrator.stop()
        self.orchestrator = nil
        // The live pass has ended — stop advertising its `live.md` (FIX 1).
        liveMarkdownURL = nil

        if let folder = currentRecordingFolder {
            await enqueueAutoRefine(folder, id)
        }
        currentRecordingFolder = nil
        status = .idle
        progressMessage = ""
        await resumeRefinement()
    }

    // MARK: - Crash handling

    /// Move to `.crashed` when the engine exits while still recording (R45).
    /// On the happy path the crash watch is cancelled before the engine exits,
    /// so reaching here genuinely means an unexpected death.
    private func handleEngineExit(recordingId: String, partialFolder: URL) async {
        guard case .recording(let id, _) = status, id == recordingId else {
            return
        }
        crashWatch = nil
        orchestrator = nil
        // The live pass is dead — stop advertising its `live.md` (FIX 1).
        liveMarkdownURL = nil
        status = .crashed(id: recordingId, partialFolderURL: partialFolder)
        progressMessage = "Recording stopped unexpectedly."
        await resumeRefinement()
    }

    /// Enqueue the partial recording for refine and return to `.idle` (R45 recovery).
    public func recoverFromCrash() async {
        guard case .crashed(let id, let partialFolder) = status,
              let partialFolder else {
            // No partial folder to recover — just clear the crash state.
            dismissCrash()
            return
        }
        await enqueueAutoRefine(partialFolder, id)
        status = .idle
        progressMessage = ""
    }

    /// Dismiss a crash banner without recovering — returns to `.idle`.
    public func dismissCrash() {
        if case .crashed = status {
            status = .idle
            progressMessage = ""
        } else if case .error = status {
            status = .idle
            progressMessage = ""
        }
    }

    // MARK: - Defaults

    /// Timestamped recording-folder basename, e.g. `2026-05-16-143005`.
    static func recordingFolderName(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: date)
    }

    /// Production binary resolver: `.build/debug/<name>` relative to the repo
    /// root derived from `#filePath`. A future change swaps this to `Bundle.main`.
    ///
    /// `public` so `pulsartrace-mac`'s `AppEnvironment` can reuse this exact
    /// resolver to locate `pulsartrace-whisper` when building the refinement
    /// queue — one source of truth for binary paths across the live engine
    /// (via `RecordOrchestrator`'s `engineEnvironment`) and refinement.
    public nonisolated static let defaultBinaryURLResolver: @Sendable (String) -> URL = { name in
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PulsarTraceMenuBar
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".build/debug/\(name)")
    }

    /// Production orchestrator factory — a real `RecordOrchestrator`.
    ///
    /// `engineEnvironment` threads `PULSARTRACE_WHISPER_BINARY` to the engine
    /// subprocess so it can locate `pulsartrace-whisper` without falling back
    /// to the resolver's `/usr/local/bin/` last-resort branch — the mac app
    /// already knows the correct `.build/debug/...` path via `resolve`.
    nonisolated static let defaultOrchestratorFactory:
        @Sendable (RecordPlan, @escaping @Sendable (String) -> URL) -> RecordingOrchestrating
    = { plan, resolve in
        RecordOrchestrator(configuration: .init(
            captureBinary: resolve("pulsartrace-capture"),
            captureArguments: plan.captureArguments,
            engineBinary: resolve("pulsartrace-engine"),
            engineArguments: plan.engineArguments,
            engineEnvironment: [
                "PULSARTRACE_WHISPER_BINARY": resolve("pulsartrace-whisper").path,
            ]))
    }
}
