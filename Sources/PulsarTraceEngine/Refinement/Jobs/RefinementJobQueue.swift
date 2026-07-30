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
    /// A hook the in-flight worker registers (via `setInflightTranscriberRelease`)
    /// that cancels the live `WhisperKitRegionTranscriber`'s in-flight decode
    /// (`cancelPending`) and then drops the `SharedTranscriberBox`.
    /// `pauseForRecording` fires it after cancelling the diarizer so the
    /// in-flight decode unwinds and the resident WhisperKit models are freed
    /// (ARC on the dropped actor) *before* the live pass loads its own model.
    /// Cleared synchronously alongside `inflightCancellable` after each job runs.
    private var inflightTranscriberRelease: (@Sendable () -> Void)?

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

    /// Register a hook for cancelling + releasing the in-flight job's shared
    /// transcriber. `pauseForRecording` invokes it after cancelling the diarizer
    /// so the in-flight decode stops (`cancelPending`) and the resident
    /// `WhisperKitRegionTranscriber`'s CoreML models are freed (ARC on the
    /// dropped actor) before the live pass loads its own model. Production
    /// `runJob` binds it to `box.peek()?.cancelPending(); box.release()`;
    /// tests pass a spy. Pass `nil` to clear.
    func setInflightTranscriberRelease(_ release: (@Sendable () -> Void)?) {
        inflightTranscriberRelease = release
    }

    /// Restore persisted jobs and kick the worker.
    ///
    /// Before reloading active jobs, prunes terminal jobs older than 30 days
    /// (matching the events-log retention policy, PT-R51 / Epic 1). A prune failure
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
    /// subprocess if one is currently running (D-Q7 / Task PT-P1-D3).
    ///
    /// **Why this does more than close the gate.** Closing the gate only stops
    /// the refiner *between* regions — an in-flight WhisperKit decode runs to
    /// completion first (its budget is `max(120 s, slice duration)`, so a
    /// whole-stream fallback region could be the entire recording length),
    /// holding the ANE/memory the live pass is about to want. So this method
    /// also:
    ///
    /// 1. Fires the in-flight transcriber-release hook (if registered), which
    ///    calls `cancelPending()` on the live `WhisperKitRegionTranscriber` —
    ///    stopping the decode at the next token boundary — then drops the
    ///    `SharedTranscriberBox`'s cached instance so ARC frees the CoreML
    ///    models.
    /// 2. Waits (bounded, 5 s) for the worker task to exit. When a decode WAS
    ///    in flight, the cancelled decode throws `CancellationError`;
    ///    `ResumableRefiner.run` propagates it (the per-region retry loop catches
    ///    only `TranscriptionError`); the worker finishes `runNext` and clears
    ///    itself within the wait. When the pause lands in a non-decode window
    ///    there is nothing to throw during the wait — the worker stays parked and
    ///    exits only after resume; see "Width of the residual 5 s wait" below.
    ///
    /// **Recovery contract — the cancelled job requeues, it does not fail.**
    /// Whenever a `CancellationError` surfaces in `runNext`'s catch — whether the
    /// in-flight decode was cancelled mid-region OR the worker's next `box.get()`
    /// threw because a non-decode-window pause POISONED the box (see below) — that
    /// path does NOT mark the job `.failed`; instead it requeues the *same* job
    /// (same id, state `.queued`) at the head of the queue and writes no
    /// `refinement_failed` / `lastError` (neither here nor in
    /// `ResumableRefiner.run`, which skips both for `CancellationError`). On the
    /// next `resumeAfterRecording`, `pumpIfIdle` re-runs that job; because its id
    /// is unchanged, `ResumableRefiner.loadOrInitProgress` matches
    /// `p.jobId == job.id` and honors the on-disk checkpoint, recomputing only
    /// the cancelled region. A few seconds of recompute, no data loss, and no
    /// terminal failure entry in `recent`.
    ///
    /// **Width of the residual 5 s wait (be honest).** The release hook only
    /// cancels an *active WhisperKit decode*. Any pause that lands during the
    /// diarize stage (long — a whole subprocess run), VAD region detection, WAV
    /// load, or parked between regions — i.e. anywhere the worker is NOT inside
    /// `pipe.transcribe` — has no decode to cancel, so `cancelPending()` is a
    /// no-op while `box.release()` still POISONS the box (terminal release). The
    /// worker does NOT unwind here: `pauseGate.waitOpen()` PARKS, it does not
    /// throw. So this method waits the full 5 s poll, then lets recording proceed
    /// with the worker still parked. The worker only exits LATER — at its next
    /// `box.get()` AFTER `resumeAfterRecording` reopens the gate — when that
    /// `get()` throws `CancellationError` off the poisoned box; `runNext`'s catch
    /// then requeues the job (per the recovery contract above) and `pumpIfIdle`
    /// re-runs it. Note that by then `resumeAfterRecording` has already cleared
    /// `pausedForRecording`, which is exactly why the requeue arm matches
    /// `CancellationError` unconditionally rather than gating on that flag. The
    /// 5 s is a ceiling on recording-start latency in those non-decode windows,
    /// not a between-regions-only cost. One nuance on the diarize window: on a
    /// system-only recording the diarize pass can run through to completion
    /// without ever reaching a `box.get()` (a correct outcome — nothing to
    /// requeue), whereas with a mic stream the worker exits at the mic-pass
    /// `get()` and requeues per the recovery contract.
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

        // Fire the transcriber-release hook so the in-flight decode is
        // cancelled (the hook calls `cancelPending()` on the live
        // `WhisperKitRegionTranscriber`, then drops the box) and the resident
        // CoreML models are freed promptly (ARC on the dropped actor) before
        // the live pass loads its own model.
        //
        // Only if a release hook was registered do we then wait for the
        // worker's exit: that wait is "I expect the in-flight decode to throw
        // `CancellationError` and the worker to unwind because I just cancelled
        // it." Without a release hook there's no such signal — historical tests
        // with `gate.waitOpen()` + `Task.sleep(60s)` runJobs would otherwise
        // pay a needless 5s timeout on every pauseForRecording. Production
        // wires the hook in `makeStandard`.
        let hadRelease = inflightTranscriberRelease != nil
        if let release = inflightTranscriberRelease {
            release()
        }

        // Wait for the worker task to actually exit so the caller has
        // happens-before with "the resident refine model is gone" before the
        // live pass loads its own. The release above cancels the in-flight
        // decode: the per-token callback returns `false`, `decode` throws
        // `CancellationError` (not a `TranscriptionError`, so the per-region
        // retry loop doesn't swallow it), `ResumableRefiner.run` propagates it,
        // and `runNext` runs to completion — clearing `worker` to nil. With the
        // cancel flag this normally settles in well under a second.
        //
        // Bounded, abandonable wait: poll `worker` for nil. (A TaskGroup racing
        // `await worker.value` against a sleep cannot time out — the group
        // drains all children before returning, and a `Task<Void, Never>.value`
        // await is itself uncancellable, so `cancelAll()` after the sleep is a
        // no-op.) Polling actor state sidesteps both.
        if hadRelease {
            let deadline = ContinuousClock.now + .seconds(5)
            // Break on caller cancellation too: a cancelled `pauseForRecording`
            // caller should not busy-spin the actor for the remaining deadline
            // (the `Task.sleep` already throws on cancel, so the loop would
            // otherwise spin tight). The job still requeues via runNext's own
            // unwind; this just stops *us* from holding the actor.
            while worker != nil, ContinuousClock.now < deadline {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if worker != nil {
                logger.warning(
                    "pauseForRecording: refinement worker did not exit within 5s; recording will proceed regardless")
            }
        }
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
            // A `CancellationError` here is NEVER a job failure — it can only
            // originate from the pause/release machinery: either the in-flight
            // WhisperKit decode being cancelled mid-region (the transcriber-
            // release hook calls `cancelPending()`, `decode` throws), or the
            // worker's next `box.get()` throwing after the box was POISONED by a
            // terminal `box.release()` during a pause that landed in a NON-decode
            // window (VAD / WAV-load / parked-between-regions — no decode to
            // cancel, so the worker doesn't unwind at `pauseForRecording` and
            // instead exits at its next `get()` AFTER `resumeAfterRecording`).
            // Either way the on-disk `refine-progress.json` still holds every
            // region completed before the cancel, keyed by THIS job's id, so the
            // correct outcome is identical: requeue the SAME job (same id,
            // `.queued`) at the HEAD of the queue and let `pumpIfIdle` re-run it.
            // `ResumableRefiner.loadOrInitProgress` matches `p.jobId == job.id`
            // and honors the checkpoint, recomputing only the cancelled region.
            // Marking it `.failed` instead would strand the checkpoint (the UI
            // Retry enqueues a FRESH id, whose progress won't match) and force a
            // full recompute, and it would leave an unpaired `refinement_failed`
            // gap (ResumableRefiner suppresses that event for CancellationError).
            //
            // Matched UNCONDITIONALLY (no `pausedForRecording` precondition):
            // when the cancel surfaces via the poisoned `get()`, the worker may
            // not resume and re-throw until AFTER `resumeAfterRecording` has
            // already cleared `pausedForRecording` — gating on it would miss that
            // interleave and misclassify to `.transcribeFailed`. Requeueing is
            // also safe in any hypothetical un-paused arrival (the job just
            // re-runs from its checkpoint). The defensive `is CancellationError →
            // .transcribeFailed` branch in `RefinementJobError.classify` is thus
            // unreachable from this queue path but kept (harmless, still right
            // for any other caller).
            if error is CancellationError {
                // Clear the per-job slots first (same happens-before reasoning
                // as the terminal path below), then requeue at the head.
                inflightCancellable = nil
                inflightTranscriberRelease = nil
                job.state = .queued
                // Defensive: never double-insert. The job was removed from
                // `queued` at the top of runNext and is not terminal, so it
                // exists in neither list now; the filter is belt-and-suspenders.
                queued.removeAll { $0.id == job.id }
                queued.insert(job, at: 0)
                try? await store.upsert(job)
                current = nil
                self.worker = nil      // clear BEFORE pumpIfIdle so guard passes
                pumpIfIdle()           // no-op while paused; resume re-pumps
                return                 // do NOT add a `recent` failure entry
            }
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
        // Same reasoning for the transcriber-release hook (Phase 6): clear
        // it synchronously so a between-jobs pauseForRecording does not
        // see (and try to invoke) a stale hook bound to the previous job's
        // already-released transcriber box.
        inflightTranscriberRelease = nil
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
    /// Production wiring: in-process `WhisperKitRegionTranscriber` (ANE) +
    /// `FluidVADRegionDetector` + production `Diarizer` + the process-wide
    /// `EventWriter`.
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
        paths: AppPaths = .standard,
        options: TranscriptionOptions = .init()
    ) async -> RefinementJobQueue {
        let store = RefinementJobStore.standard(paths: paths)
        let gate = PauseGate(initiallyOpen: true)

        // Two-step init: queue is constructed first with a placeholder closure,
        // then `setRunJob` replaces it with the real one that captures the queue.
        // This breaks the chicken-and-egg: the real runJob needs to call
        // `queue.setInflightCancellable(diarizer)` so the queue can cancel the
        // diarizer on pause (D-Q7 / Task PT-P1-D3).
        //
        // Weak capture: `runJob` is stored on the queue itself, which would
        // create a retain cycle with a strong capture. Using `[weak queue]`
        // breaks the cycle. The guard-let at the top of the closure exits
        // early if the queue is ever deallocated (safe no-op).
        let queue = RefinementJobQueue(store: store, runJob: { _ in }, pauseGate: gate)

        // Persistent speaker library — same path OfflineRefiner uses. A
        // failure to open it is non-fatal: each job falls back to raw
        // Speaker_N labels rather than the library names (PT-R22/PT-R23). The
        // library actor is opened once and shared across jobs.
        let library: SpeakerLibrary? = try? await SpeakerLibrary(
            databaseURL: paths.speakersDatabaseURL, events: events)

        // PT-P8-R3 (a): passive owner-profile learning — the store lives beside
        // the speaker library, never inside it. Each ordinary refine feeds the
        // dedup-surviving mic speech into the inlier-gated profile.
        let ownerProfile = OwnerVoiceProfileStore(fileURL: paths.ownerProfileURL)

        let runJob: RunJob = { [weak queue] job in
            guard let queue else { return }
            // ANE refine (PT-P5-D1): in-process WhisperKit + FluidAudio VAD. The
            // job's model name resolves against the WhisperKit catalog; an
            // unknown name (e.g. a job enqueued by an older build) falls
            // back to the default rather than failing the job.
            let model = WhisperKitModelCatalog.model(named: job.modelName)
                ?? WhisperKitModelCatalog.defaultModel

            // Normalize retired model names (e.g. a pre-PT-P5-D1 "base" enqueued by an
            // older build) so the events/metadata path downstream reports the
            // model actually used for the decode, not the stale enqueue-time name.
            // `RefinementJob.modelName` is a `let`, so reconstruct via the
            // initializer when it diverges from the resolved model.
            let job: RefinementJob = model.name == job.modelName ? job : RefinementJob(
                id: job.id,
                recordingId: job.recordingId,
                folderURL: job.folderURL,
                modelName: model.name,
                // PT-P5-D1 — SDK-managed bundle, no pin; clears the retired ggml digest.
                modelSHA256: "",
                trigger: job.trigger,
                enqueuedAt: job.enqueuedAt,
                state: job.state)

            let diarizer = OfflineRefiner.makeDiarizer(events: events)

            // Register the diarizer so pauseForRecording() can cancel it
            // mid-run (D-Q7). Clearing the slot is the queue's
            // responsibility (done synchronously in runNext() after _runJob
            // returns).
            await queue.setInflightCancellable(diarizer)

            // One transcriber per *job*, not per region — the model loads
            // once on the first region decode and stays resident across the
            // job. The release hook below lets pauseForRecording() cancel the
            // in-flight decode and drop the box's actor: the cancel unwedges
            // the decode and ARC frees the CoreML models — the in-process
            // analogue of SIGTERMing the old `pulsartrace-whisper` subprocess
            // before a recording starts.
            let box = SharedTranscriberBox<WhisperKitRegionTranscriber> {
                WhisperKitRegionTranscriber(
                    configuration: .init(
                        model: model,
                        downloadBase: paths.modelsCacheDirectory
                            .appendingPathComponent("whisperkit", isDirectory: true)),
                    events: events)
            }
            let vad = FluidVADRegionDetector()
            // Release hook (fired by pauseForRecording on a recording start):
            // first signal the live transcriber to stop its in-flight decode at
            // the next token boundary (`cancelPending` throws CancellationError
            // out of the worker), then drop the box so ARC frees the resident
            // CoreML models. `peek()` reaches the instance without building one
            // — a job that never decoded has nothing to cancel.
            await queue.setInflightTranscriberRelease { [box] in
                box.peek()?.cancelPending()
                box.release()
            }

            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try box.get()
                    return try await t.transcribeRegion(
                        samples, region: region, options: options)
                },
                detectRegions: { samples in
                    do {
                        return try await vad.detectRegions(samples)
                    } catch {
                        // VAD failure must not lose a refine: one region
                        // spanning the whole stream — WhisperKit's internal
                        // seek loop handles the length. (The old path's
                        // equivalent fallback was the whole-buffer decode.)
                        return [SpeechRegion(
                            start: .zero,
                            end: .milliseconds(
                                samples.count * 1000 / AudioFormat.sampleRate))]
                    }
                },
                diarize: { wav in
                    try await diarizer.diarizeSystemStream(wavPath: wav)
                },
                pauseGate: gate,
                events: events,
                library: library,
                ownerProfile: ownerProfile,
                options: options,
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
