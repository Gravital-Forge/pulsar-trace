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
    public func start() async throws {
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
    /// no job is currently running.
    public func reportStage(_ state: RefinementJobState) {
        guard var job = current else { return }
        job.state = state
        current = job
        Task { try? await self.store.upsert(job) }
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
    /// so the in-flight refiner stalls at its next checkpoint. Also signals
    /// the diarizer to terminate its subprocess if one is currently running
    /// (D-Q7 / Task D3).
    public func pauseForRecording() async {
        pausedForRecording = true
        await pauseGate.close()
        if let c = inflightCancellable { await c.cancel() }
    }

    /// Resume the queue: opens the gate (the in-flight refiner picks up at its
    /// next checkpoint) and lets the worker pump again.
    public func resumeAfterRecording() async {
        pausedForRecording = false
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
            job.state = .completed(durationSeconds: 0.0, speakerCount: 0)
        } catch {
            // TODO Task C3: extract a typed error class + retry flag.
            job.state = .failed(errorClass: "io", retryAvailable: true)
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
        current = nil
        self.worker = nil        // clear BEFORE pumpIfIdle so guard passes
        pumpIfIdle()
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
    /// The `settings` parameter is a forward hook for when the queue
    /// auto-selects a model per-job (e.g. user preference stored in
    /// `AppEnvironment`). It is not yet consumed in the body — the job's
    /// `modelName` field drives model selection today. A TODO marks the
    /// integration point so Phase-E or the AppEnvironment wiring can
    /// fill it in without changing this signature.
    public static func makeStandard(
        events: EventWriter,
        paths: AppPaths = .standard,
        settings: @escaping @Sendable () -> (model: WhisperModel, sha256: String)
    ) async -> RefinementJobQueue {
        // TODO C5/D-followup: consume `settings` once the queue auto-picks
        // a model independently of the job's stored modelName field.
        let store = RefinementJobStore.standard(paths: paths)
        let gate = PauseGate(initiallyOpen: true)

        // Two-step init: queue is constructed first with a placeholder closure,
        // then `setRunJob` replaces it with the real one that captures the queue.
        // This breaks the chicken-and-egg: the real runJob needs to call
        // `queue.setInflightCancellable(diarizer)` so the queue can cancel the
        // diarizer on pause (D-Q7 / Task D3).
        //
        // NOTE: the queue is strongly captured inside `runJob`, which is stored
        // on the queue itself. This creates a retain cycle. In production this
        // is acceptable — the queue lives for the app's lifetime. (TODO D3: if
        // a unit-level makeStandard test is added, break the cycle via a weak
        // capture or a separate factory object.)
        let queue = RefinementJobQueue(store: store, runJob: { _ in }, pauseGate: gate)

        let runJob: RunJob = { [queue] job in
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

            // WhisperTranscriber is NOT Sendable (whisper_context is not
            // thread-safe). Creating a new instance per-region is the accepted
            // project pattern — OfflineRefiner uses a transcriberFactory for
            // the same reason. The model file is mmapped by whisper.cpp so the
            // OS page-cache amortises the cost across calls.
            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try WhisperTranscriber(modelURL: modelURL)
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
                // TODO C5/D-followup: wire onStageUpdate to queue.reportStage
                // once a forward-reference mechanism exists. Options explored:
                // Box<RefinementJobQueue?>, 2-step init with a mutable runJob
                // slot, or a separate ObservableStageProxy. Deferred to Phase-E
                // stage-progress UI work (E1/E4).
                events: events)
            try await refiner.run(job: job)
        }

        await queue.setRunJob(runJob)
        try? await queue.start()
        return queue
    }
}
