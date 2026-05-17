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

/// Drives one menubar recording session: start → record → refine → idle, with
/// crash detection (R40, R45).
///
/// `@MainActor @Observable` so the menubar binds to `status` / `progressMessage`
/// directly. Orchestration (process spawning) is behind the
/// `RecordingOrchestrating` seam and a `reRefiner` closure so the whole status
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
    /// `#filePath`; Epic 10 swaps this to `Bundle.main`.
    private let binaryURLResolver: @Sendable (String) -> URL

    /// Drives the post-recording refine pass.
    private let reRefiner: @Sendable (URL) async throws -> Void

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
    ///   - events: the process-wide events writer the in-process re-refine
    ///     emits through; `nil` only in tests that inject their own `reRefiner`.
    ///   - clock: injectable wall clock (deterministic tests).
    ///   - binaryURLResolver: name → binary URL (default `.build/debug/<name>`).
    ///   - orchestratorFactory: builds the orchestration seam — default builds a
    ///     real `RecordOrchestrator`; tests inject a stub factory.
    ///   - reRefiner: drives the offline refine pass after the live pass ends.
    ///     The default runs `OfflineRefiner` **in-process** (D23 — the menubar
    ///     never shells out to the `pulsartrace` CLI); tests inject a stub.
    public init(
        settings: MenuBarSettings,
        paths: AppPaths = .standard,
        events: EventWriter? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        binaryURLResolver: (@Sendable (String) -> URL)? = nil,
        orchestratorFactory: (@Sendable (RecordPlan, @escaping @Sendable (String) -> URL)
            -> RecordingOrchestrating)? = nil,
        reRefiner: (@Sendable (URL) async throws -> Void)? = nil
    ) {
        self.settings = settings
        self.paths = paths
        self.clock = clock
        self.binaryURLResolver = binaryURLResolver
            ?? RecordingViewModel.defaultBinaryURLResolver
        self.orchestratorFactory = orchestratorFactory
            ?? RecordingViewModel.defaultOrchestratorFactory
        self.reRefiner = reRefiner
            ?? RecordingViewModel.makeDefaultReRefiner(
                settings: settings, paths: paths, events: events)
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

        // KNOWN ISSUE (deferred — see Epic 10 first-run permissions wizard):
        // starting without TCC mic/system-audio grants races the OS permission
        // prompt — `orchestrator.start` can fail and surface a "permissions
        // not granted" error before the user has finished responding to the
        // prompt. Deliberately left as-is; the Epic 10 first-run wizard will
        // request and confirm grants up front, before the first start.
        do {
            try await orchestrator.start(readyTimeout: .seconds(20))
        } catch {
            self.orchestrator = nil
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

    /// Stop the in-flight recording and run the refine pass (R40, R41).
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

        await runRefine(recordingId: id, folderOverride: currentRecordingFolder)
    }

    // MARK: - Crash handling

    /// Move to `.crashed` when the engine exits while still recording (R45).
    /// On the happy path the crash watch is cancelled before the engine exits,
    /// so reaching here genuinely means an unexpected death.
    private func handleEngineExit(recordingId: String, partialFolder: URL) {
        guard case .recording(let id, _) = status, id == recordingId else {
            return
        }
        crashWatch = nil
        orchestrator = nil
        // The live pass is dead — stop advertising its `live.md` (FIX 1).
        liveMarkdownURL = nil
        status = .crashed(id: recordingId, partialFolderURL: partialFolder)
        progressMessage = "Recording stopped unexpectedly."
    }

    /// Refine the partial recording captured before a crash (R45 recovery).
    public func recoverFromCrash() async {
        guard case .crashed(let id, let partialFolder) = status,
              let partialFolder else {
            // No partial folder to recover — just clear the crash state.
            dismissCrash()
            return
        }
        await runRefine(recordingId: id, folderOverride: partialFolder)
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

    // MARK: - Refine

    /// Run the offline refine pass, then return to `.idle`.
    private func runRefine(recordingId: String, folderOverride: URL? = nil) async {
        status = .refining(id: recordingId)
        progressMessage = "Refining transcript…"

        let folder: URL?
        if let folderOverride {
            folder = folderOverride
        } else {
            // The recording folder is the most recent under the output root.
            folder = settings.outputFolderURL.flatMap { root in
                RecordingsScanner.scanRoot(root)
                    .first { $0.id == recordingId }?.folderURL
            }
        }

        if let folder {
            do {
                try await reRefiner(folder)
                progressMessage = "Done."
            } catch {
                progressMessage = "Refine failed: \(error)"
            }
        } else {
            progressMessage = "Recording saved (refine skipped — folder not found)."
        }
        currentRecordingFolder = nil
        status = .idle
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
    /// root derived from `#filePath`. Epic 10 swaps this to `Bundle.main`.
    nonisolated static let defaultBinaryURLResolver: @Sendable (String) -> URL = { name in
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PulsarTraceMenuBar
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".build/debug/\(name)")
    }

    /// Production orchestrator factory — a real `RecordOrchestrator`.
    nonisolated static let defaultOrchestratorFactory:
        @Sendable (RecordPlan, @escaping @Sendable (String) -> URL) -> RecordingOrchestrating
    = { plan, resolve in
        RecordOrchestrator(configuration: .init(
            captureBinary: resolve("pulsartrace-capture"),
            captureArguments: plan.captureArguments,
            engineBinary: resolve("pulsartrace-engine"),
            engineArguments: plan.engineArguments))
    }

    /// Production re-refiner: runs `OfflineRefiner` **in-process** (D23 — the
    /// menubar must not shell out to the `pulsartrace` CLI). A refine failure
    /// is propagated, never swallowed.
    ///
    /// Requires an `EventWriter` so the refine emits the same events the CLI
    /// path does; when `events` is `nil` (a test path that did not inject a
    /// `reRefiner`) the closure throws rather than silently no-op. Called from
    /// the `@MainActor` init, so `settings.refineModelName` is read here.
    static func makeDefaultReRefiner(
        settings: MenuBarSettings,
        paths: AppPaths,
        events: EventWriter?
    ) -> @Sendable (URL) async throws -> Void {
        let modelName = settings.refineModelName
        return { folderURL in
            guard let events else { throw RefineUnavailableError.noEventWriter }
            let model = ModelCatalog.model(named: modelName) ?? ModelCatalog.base
            let refiner = OfflineRefiner(events: events, paths: paths)
            _ = try await refiner.refine(inputPath: folderURL, model: model)
        }
    }

    /// Raised when an in-process re-refine cannot run because no `EventWriter`
    /// was provided (a misconfigured non-test caller).
    enum RefineUnavailableError: Error, CustomStringConvertible {
        case noEventWriter
        var description: String {
            "re-refine unavailable: no events writer configured"
        }
    }
}
