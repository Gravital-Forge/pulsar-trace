// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift
import Foundation
import Logging

/// The single-worker refinement queue. Drives exactly one
/// `ResumableRefiner.run` at a time; queues the rest in FIFO order.
///
/// State exposed via `snapshot()` (a value type the UI re-reads). The
/// menubar layer wraps this actor in a `@MainActor @Observable` façade
/// (`RefinementJobQueueViewModel`).
public actor RefinementJobQueue {

    /// One snapshot of the queue's state — what the UI binds to.
    public struct Snapshot: Sendable, Equatable {
        public let running: RefinementJob?
        public let queued: [RefinementJob]
        public let recent: [RefinementJob]   // terminal jobs, newest first
        public let pausedForRecording: Bool
    }

    public typealias RunJob = @Sendable (RefinementJob) async throws -> Void

    private let store: RefinementJobStore
    private var _runJob: RunJob
    private let pauseGate: PauseGate
    private let logger: Logger

    private var current: RefinementJob?
    private var queued: [RefinementJob] = []
    private var recent: [RefinementJob] = []
    private var pausedForRecording = false
    private var worker: Task<Void, Never>?
    private var inflightCancellable: RefinementCancellable?

    /// Cap on the in-memory `recent` list. Older terminal jobs still exist
    /// on disk until `pruneTerminal` reaps them; this just bounds memory
    /// and the size of every `snapshot()` reply during a long session.
    private static let recentMemoryCap = 100

    public init(
        store: RefinementJobStore,
        runJob: @escaping RunJob,
        pauseGate: PauseGate = PauseGate(initiallyOpen: true),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.store = store
        self._runJob = runJob
        self.pauseGate = pauseGate
        self.logger = logger
    }

    /// Replace the run-job closure after construction. Used in `makeStandard`
    /// to break the chicken-and-egg between queue construction and the closure
    /// that needs to capture the queue (to call `setInflightCancellable`).
    func setRunJob(_ runJob: @escaping RunJob) {
        self._runJob = runJob
    }

    /// Register the cancellable for the in-flight job. Production `runJob`
    /// passes a `Diarizer`; tests pass a spy. Pass `nil` to clear.
    func setInflightCancellable(_ cancellable: RefinementCancellable?) {
        inflightCancellable = cancellable
    }

    /// Restore persisted jobs and kick the worker.
    ///
    /// Before reloading active jobs, prunes terminal jobs older than 30 days
    /// (matching the events-log retention policy, R51 / Epic 1). A prune failure
    /// is non-fatal: it logs a warning and queue startup continues normally.
    public func start() async throws {
        do {
            try await store.pruneTerminal(olderThanDays: 30)
        } catch {
            logger.warning("refinement queue: pruneTerminal failed (non-fatal): \(PathRedactor.redactHome("\(error)"))")
        }
        let persisted = try await store.listAll()
        for job in persisted {
            switch job.state {
            case .queued, .running, .paused:
                var requeued = job
                requeued.state = .queued
                self.queued.append(requeued)
                try? await store.upsert(requeued)
            case .completed, .failed, .cancelled:
                self.recent.append(job)
            }
        }
        trimRecent()
        pumpIfIdle()
    }

    /// Enqueue a manual refine (recordings list "Refine" button).
    public func enqueueManualRefine(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String
    ) async throws {
        try await enqueue(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256,
            trigger: .manual)
    }

    /// Enqueue a post-recording auto refine.
    public func enqueueAutoRefine(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String
    ) async throws {
        try await enqueue(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256,
            trigger: .autoPostRecording)
    }

    /// Enqueue a crash-recovery refine.
    public func enqueueCrashRecovery(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String
    ) async throws {
        try await enqueue(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256,
            trigger: .crashRecovery)
    }

    private func enqueue(
        folderURL: URL, recordingId: String,
        modelName: String, modelSHA256: String,
        trigger: RefinementJob.Trigger
    ) async throws {
        // D-Q4: at most one job per recording. If one already exists
        // (queued or running), the new request is a no-op.
        if current?.recordingId == recordingId
            || queued.contains(where: { $0.recordingId == recordingId }) {
            return
        }

        let job = RefinementJob(
            id: "job_\(ULID.generate().description)",
            recordingId: recordingId,
            folderURL: folderURL,
            modelName: modelName,
            modelSHA256: modelSHA256,
            trigger: trigger,
            enqueuedAt: Date(),
            state: .queued)
        try await store.upsert(job)
        queued.append(job)
        pumpIfIdle()
    }

    /// Update the running job's `state` from inside the refiner. A no-op when
    /// no job is currently running. Awaits the on-disk persist so callers see
    /// the new state durable before returning — a fire-and-forget upsert lost
    /// ordering on bursty updates and dropped errors via `try?`.
    public func reportStage(_ state: RefinementJobState) async {
        guard var job = current else { return }
        job.state = state
        current = job
        do {
            try await store.upsert(job)
        } catch {
            logger.warning("reportStage upsert failed: \(PathRedactor.redactHome("\(error)"))")
        }
    }

    /// Read-only state snapshot for the UI.
    public func snapshot() -> Snapshot {
        Snapshot(
            running: current,
            queued: queued,
            recent: Array(recent.reversed()),
            pausedForRecording: pausedForRecording)
    }

    /// Pause the queue: stops new jobs from starting and closes the pause gate
    /// so the in-flight refiner stalls at its next checkpoint. Transforms the
    /// running job's `.running(stage:, …)` into `.paused(reason: .recordingInProgress,
    /// lastStage:)` so the UI reflects the suspension rather than showing
    /// stale "Diarizing 2/7" text. Also signals the diarizer to terminate its
    /// subprocess if one is currently running (D-Q7 / Task D3).
    public func pauseForRecording() async {
        pausedForRecording = true
        await pauseGate.close()
        if var job = current,
           case .running(let stage, _, _, _, _) = job.state {
            job.state = .paused(reason: .recordingInProgress, lastStage: stage)
            current = job
            do { try await store.upsert(job) }
            catch { logger.warning("pause upsert failed: \(PathRedactor.redactHome("\(error)"))") }
        }
        if let c = inflightCancellable { await c.cancel() }
    }

    /// Resume the queue: opens the gate so the in-flight refiner picks up at
    /// its next checkpoint. Transforms the running job's `.paused` back into
    /// `.running` so the UI reports forward progress again. The actual step
    /// counts will be overwritten by the refiner's next `reportStage` call;
    /// here we restore a sensible baseline derived from `lastStage`.
    public func resumeAfterRecording() async {
        pausedForRecording = false
        if var job = current,
           case .paused(_, let lastStage) = job.state {
            let stepIndex = RefinementJobState.Stage.allCases.firstIndex(of: lastStage) ?? 0
            job.state = .running(
                stage: lastStage,
                stepsCompleted: stepIndex,
                stepsTotal: RefinementJobState.Stage.allCases.count,
                regionIndex: nil, regionsTotal: nil)
            current = job
            do { try await store.upsert(job) }
            catch { logger.warning("resume upsert failed: \(PathRedactor.redactHome("\(error)"))") }
        }
        await pauseGate.open()
        pumpIfIdle()
    }

    /// Cancel a queued job. A no-op if no queued job with that recording id
    /// exists. Running and terminal jobs are not affected here — for those,
    /// the caller must wait (running can finish naturally) or delete the
    /// terminal record via the store directly.
    public func cancel(recordingId: String) async {
        guard let i = queued.firstIndex(where: { $0.recordingId == recordingId })
        else { return }
        var job = queued.remove(at: i)
        job.state = .cancelled
        try? await store.upsert(job)
        recent.append(job)
        trimRecent()
    }

    private func pumpIfIdle() {
        guard current == nil, !queued.isEmpty, worker == nil,
              !pausedForRecording else { return }
        worker = Task { await self.runNext() }
    }

    private func runNext() async {
        guard !queued.isEmpty else { self.worker = nil; return }
        var job = queued.removeFirst()
        job.state = .running(
            stage: .resolvingInput,
            stepsCompleted: 0,
            stepsTotal: RefinementJobState.Stage.allCases.count,
            regionIndex: nil, regionsTotal: nil)
        try? await store.upsert(job)
        current = job

        do {
            try await _runJob(job)
            // Read metadata.json written by the refiner to populate real stats.
            let metadataURL = job.folderURL.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metadataURL),
               let metadata = try? JSONDecoder().decode(RefinementMetadata.self, from: data) {
                job.state = .completed(
                    durationSeconds: metadata.durationSeconds,
                    speakerCount: metadata.speakers.count)
            } else {
                logger.warning("could not read metadata.json after refine — completion will show 0s/0 speakers")
                job.state = .completed(durationSeconds: 0.0, speakerCount: 0)
            }
        } catch {
            let classified = RefinementJobError.classify(error)
            job.state = .failed(
                errorClass: classified.errorClass,
                retryAvailable: classified.retryAvailable)
        }
        // Clear the cancellable synchronously here — before pumpIfIdle() can
        // start the next job's runJob and register a new cancellable. This
        // guarantees happens-before ordering: a pauseForRecording() called
        // between jobs sees nil (correct: no job is running) rather than
        // potentially seeing the *previous* job's cancellable if the
        // fire-and-forget cleanup Task lost the race (D-Q7 lost-cancel fix).
        inflightCancellable = nil
        try? await store.upsert(job)
        recent.append(job)
        trimRecent()
        current = nil
        self.worker = nil        // clear BEFORE pumpIfIdle so guard passes
        pumpIfIdle()
    }

    /// Keep the in-memory `recent` list bounded. The newest entries (the
    /// tail) are preserved; older entries are dropped from memory only —
    /// disk-side files persist until `pruneTerminal` reaps them.
    private func trimRecent() {
        if recent.count > Self.recentMemoryCap {
            let drop = recent.count - Self.recentMemoryCap
            recent.removeFirst(drop)
        }
    }
}

// MARK: - Production factory

extension RefinementJobQueue {
    /// Production wiring: real `WhisperTranscriber` + production
    /// `Diarizer` + the process-wide `EventWriter`.
    ///
    /// Used by `AppEnvironment` in `pulsartrace-mac`. The CLI's
    /// `OfflineRefiner` path stays unchanged (one-shot, no queue).
    ///
    /// Per-job model selection is determined at enqueue time: callers pass
    /// `modelName` and `modelSHA256` to `enqueueManualRefine` /
    /// `enqueueAutoRefine` / `enqueueCrashRecovery`. The queue reads these
    /// fields from each `RefinementJob` at run time.
    public static func makeStandard(
        events: EventWriter,
        paths: AppPaths = .standard
    ) async -> RefinementJobQueue {
        let store = RefinementJobStore.standard(paths: paths)
        let gate = PauseGate(initiallyOpen: true)

        // Two-step init: queue is constructed first with a placeholder closure,
        // then `setRunJob` replaces it with the real one that captures the queue.
        // This breaks the chicken-and-egg: the real runJob needs to call
        // `queue.setInflightCancellable(diarizer)` so the queue can cancel the
        // diarizer on pause (D-Q7 / Task D3).
        //
        // Weak capture: `runJob` is stored on the queue itself, which would
        // create a retain cycle with a strong capture. Using `[weak queue]`
        // breaks the cycle. The guard-let at the top of the closure exits
        // early if the queue is ever deallocated (safe no-op).
        let queue = RefinementJobQueue(store: store, runJob: { _ in }, pauseGate: gate)

        // Persistent speaker library — same path OfflineRefiner uses. A
        // failure to open it is non-fatal: each job falls back to raw
        // Speaker_N labels rather than the library names (R22/R23). The
        // library actor is opened once and shared across jobs.
        let library: SpeakerLibrary? = try? await SpeakerLibrary(
            databaseURL: paths.speakersDatabaseURL, events: events)

        let runJob: RunJob = { [weak queue] job in
            guard let queue else { return }
            let modelStore = ModelStore(events: events)
            let modelURL = try await modelStore.ensureAvailable(
                ModelCatalog.model(named: job.modelName) ?? ModelCatalog.base)

            // VAD failure is non-fatal: fall back to whole-buffer transcription
            // (matches OfflineRefiner.refine behaviour for consistency).
            let vadURL = try? await modelStore.ensureAvailable(ModelCatalog.sileroVAD)

            let diarizer = try OfflineRefiner.makeDiarizer()

            // Register the diarizer so pauseForRecording() can cancel it mid-run
            // (D-Q7). Clearing the slot is the queue's responsibility (done
            // synchronously in runNext() after _runJob returns), which guarantees
            // the cancellable is nil before the next job can register its own —
            // eliminating the lost-cancel race that a fire-and-forget Task cleanup
            // would have introduced.
            await queue.setInflightCancellable(diarizer)

            // One transcriber per *job*, not per region. The historical
            // cost driver was `whisper_init_from_file_with_params` rebuilding
            // the Metal pipeline state on every call (DECISIONS.md D36,
            // reopened); the remote variant keeps the same shape — one
            // subprocess spawned on first region, reused across every region
            // of the job. The queue's single-worker invariant + the host's
            // single-connection lifecycle together serialise every touch.
            //
            // Phase 5 (docs/specs/2026-05-26-whisper-subprocess-design.md
            // §6/§7): the in-process `WhisperTranscriber` is replaced by
            // `RemoteRegionTranscriber` so a wedged refinement decode is
            // recoverable via SIGKILL + respawn without losing already-
            // checkpointed regions.
            let sharedTranscriber = SharedTranscriberBox<any RegionTranscribing> {
                let remoteConfig = RemoteRegionTranscriber.Configuration(
                    binaryURL: WhisperBinaryResolver.defaultBinaryURL(),
                    modelURL: modelURL,
                    socketDirectory: AppPaths.standard.socketDirectory)
                return RemoteRegionTranscriber(
                    configuration: remoteConfig,
                    logger: Logger(label: LogSubsystem.engine))
            }
            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try sharedTranscriber.get()
                    return try t.transcribeRegion(samples, region: region, options: options)
                },
                detectRegions: { samples in
                    guard let vadURL else { return [] }
                    return try WhisperTranscriber.detectSpeechRegions(
                        in: samples, vadModelURL: vadURL)
                },
                diarize: { wav in
                    try await diarizer.diarizeSystemStream(wavPath: wav)
                },
                pauseGate: gate,
                events: events,
                library: library,
                onStageUpdate: { [weak queue] state in
                    guard let queue else { return }
                    await queue.reportStage(state)
                })
            try await refiner.run(job: job)
        }

        await queue.setRunJob(runJob)
        try? await queue.start()
        return queue
    }

}
