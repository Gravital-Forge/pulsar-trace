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
    private let runJob: RunJob
    private let pauseGate: PauseGate
    private let logger: Logger

    private var current: RefinementJob?
    private var queued: [RefinementJob] = []
    private var recent: [RefinementJob] = []
    private var pausedForRecording = false
    private var worker: Task<Void, Never>?

    public init(
        store: RefinementJobStore,
        runJob: @escaping RunJob,
        pauseGate: PauseGate = PauseGate(initiallyOpen: true),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.store = store
        self.runJob = runJob
        self.pauseGate = pauseGate
        self.logger = logger
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
    /// the diarizer to SIGSTOP its subprocess (Task D1 wires that in).
    public func pauseForRecording() async {
        pausedForRecording = true
        await pauseGate.close()
    }

    /// Resume the queue: opens the gate (the in-flight refiner picks up at its
    /// next checkpoint) and lets the worker pump again.
    public func resumeAfterRecording() async {
        pausedForRecording = false
        await pauseGate.open()
        pumpIfIdle()
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
            try await runJob(job)
            job.state = .completed(durationSeconds: 0.0, speakerCount: 0)
        } catch {
            // TODO Task C3: extract a typed error class + retry flag.
            job.state = .failed(errorClass: "io", retryAvailable: true)
        }
        try? await store.upsert(job)
        recent.append(job)
        current = nil
        self.worker = nil        // clear BEFORE pumpIfIdle so guard passes
        pumpIfIdle()
    }
}
