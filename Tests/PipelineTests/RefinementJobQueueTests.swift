// Tests/PipelineTests/RefinementJobQueueTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementJobQueue")
struct RefinementJobQueueTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One-shot open/wait gate — same pattern as RecordingViewModelTests.Gate.
    actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() {
            guard !opened else { return }
            opened = true
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Enqueueing a job runs it through the injected refiner closure to
    /// completion; the queue then becomes idle.
    @Test("one enqueued job runs and the queue ends idle")
    func runsOneJob() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let ran = Gate()
        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in await ran.open() })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_x",
            modelName: "base",
            modelSHA256: "deadbeef")

        await ran.wait()

        // The runJob closure opened `ran` synchronously, but the queue's
        // housekeeping (state → .completed, store.upsert, recent.append,
        // current = nil) happens *after* that — possibly across a store-actor
        // await suspension. Poll the queue snapshot deterministically until
        // the post-job state has landed, rather than relying on a fixed sleep.
        var snapshot = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !(snapshot.running == nil && snapshot.recent.count == 1) {
            try await Task.sleep(for: .milliseconds(5))
            snapshot = await queue.snapshot()
        }
        #expect(snapshot.running == nil)
        #expect(snapshot.queued.isEmpty)
        #expect(snapshot.recent.count == 1)
    }

    /// `pauseForRecording()` stalls a job mid-run; `resumeAfterRecording()`
    /// finishes it. The in-flight job is the same one before and after.
    ///
    /// Two-gate design:
    /// 1. `pauseGate` starts OPEN so `waitOpen()` passes through normally.
    /// 2. `started` signals that runJob is executing.
    /// 3. `pauseSignaled` lets the test signal "I've called pauseForRecording();
    ///    now enter waitOpen() — the gate is already closed."
    /// 4. `finished` signals runJob ran to completion.
    ///
    /// This eliminates the race AND verifies that `pauseForRecording()` actually
    /// causes the stall: runJob cannot reach `finished.open()` until the test
    /// calls `resumeAfterRecording()`, which re-opens `pauseGate`.
    ///
    /// Snapshot assertions after pause (before resume) verify:
    /// - `pausedForRecording == true` — proves the flag flipped.
    /// - `running != nil` — proves the job was not aborted.
    /// If `pauseForRecording()` were removed, the first assertion would fail.
    @Test("pauseForRecording stalls in-flight; resume continues the same job")
    func pauseAndResume() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let pauseGate = PauseGate(initiallyOpen: true)   // queue's gate — starts open
        let started = Gate()        // runJob signals it is executing
        let pauseSignaled = Gate()  // test signals pauseForRecording() has been called
        let finished = Gate()       // runJob signals it ran to completion

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in
                await started.open()         // signal: job is running
                await pauseSignaled.wait()   // wait until test has called pauseForRecording()
                // At this point pauseGate is closed. waitOpen() will block until
                // resumeAfterRecording() re-opens it.
                await pauseGate.waitOpen()
                await finished.open()        // signal: job completed
            },
            pauseGate: pauseGate)
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_x",
            modelName: "base", modelSHA256: "deadbeef")

        // Wait until runJob is executing and parked on pauseSignaled.
        await started.wait()

        // Close the gate via pauseForRecording(), THEN let runJob enter waitOpen().
        await queue.pauseForRecording()

        // Verify the pause flag flipped and the in-flight job was not aborted.
        // If pauseForRecording() were removed, these assertions would fail.
        let pausedSnap = await queue.snapshot()
        #expect(pausedSnap.pausedForRecording == true)
        #expect(pausedSnap.running?.recordingId == "rec_x")

        // Let runJob proceed to waitOpen() — it must stall there (gate is closed).
        await pauseSignaled.open()

        // resumeAfterRecording() re-opens pauseGate; runJob unblocks and finishes.
        await queue.resumeAfterRecording()
        await finished.wait()

        // Poll for post-job housekeeping (same pattern as other tests).
        var snap = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !(snap.running == nil && snap.recent.count == 1) {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.pausedForRecording == false)
        #expect(snap.running == nil)
        #expect(snap.recent.count == 1)
    }

    /// `cancel(recordingId:)` removes a queued (not-yet-running) job and
    /// moves it to `recent` with state `.cancelled`. The currently running
    /// job is not affected.
    ///
    /// Design: a `PauseGate(initiallyOpen: false)` keeps `rec_a` running
    /// forever (the worker suspends in `waitOpen()`). Bounded polling waits
    /// until `rec_a` is confirmed running before cancelling the still-queued
    /// `rec_b`. The gate is opened at the end so the worker can drain before
    /// the process exits.
    @Test("cancel removes a queued (not-yet-running) job")
    func cancelQueued() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let neverFinishes = PauseGate(initiallyOpen: false)
        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in await neverFinishes.waitOpen() })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/a"), recordingId: "rec_a",
            modelName: "base", modelSHA256: "deadbeef")
        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/b"), recordingId: "rec_b",
            modelName: "base", modelSHA256: "deadbeef")

        // Bounded polling: wait until the worker claims rec_a as running.
        var snap = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, snap.running?.recordingId != "rec_a" {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.running?.recordingId == "rec_a")

        let toCancel = snap.queued.first?.recordingId ?? ""
        #expect(toCancel == "rec_b")    // make the expected order explicit
        await queue.cancel(recordingId: toCancel)

        let s = await queue.snapshot()
        #expect(s.queued.allSatisfy { $0.recordingId != toCancel })
        #expect(s.recent.contains { $0.recordingId == toCancel && $0.state == .cancelled })

        // Open the gate so the worker can drain and the Task does not
        // outlive the test process with an orphaned suspension.
        await neverFinishes.open()
    }

    /// `reportStage` updates `snapshot().running.state` so the UI can track
    /// which stage the refiner is in without polling the store.
    ///
    /// Design: the `runJob` closure blocks on a `PauseGate(initiallyOpen: false)`
    /// so the job stays in-flight for the whole test. We drive `reportStage`
    /// directly (simulating what the refiner will do in C5) and check the
    /// snapshot reflects the new stage. Bounded polling replaces any sleep
    /// for the "job is running" assertion.
    @Test("a running job's snapshot reflects the latest stage update")
    func runningStageUpdates() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let gate = PauseGate(initiallyOpen: false)
        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in await gate.waitOpen() })  // blocks for the whole test
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"), recordingId: "rec_x",
            modelName: "base", modelSHA256: "deadbeef")

        // Bounded polling: wait until the queue claims the job as running.
        var snap = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, snap.running?.recordingId != "rec_x" {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.running?.recordingId == "rec_x")

        // The refiner would normally call reportStage; here we drive it directly.
        await queue.reportStage(.running(
            stage: .transcribingSystem,
            stepsCompleted: 1, stepsTotal: 7,
            regionIndex: 3, regionsTotal: 10))
        let running = await queue.snapshot().running
        if case .running(let stage, _, _, let r, let rt) = running?.state {
            #expect(stage == .transcribingSystem)
            #expect(r == 3 && rt == 10)
        } else {
            Issue.record("expected running state")
        }

        await gate.open()
    }

    /// `pauseForRecording()` calls `cancel()` on the registered inflight
    /// cancellable (D-Q7 / Task D3). A spy actor records whether it was hit.
    ///
    /// Design: a `setRunJob` setter lets us capture `queue` inside `runJob`
    /// after construction, breaking the chicken-and-egg. The runJob registers
    /// the spy, signals `started`, then parks on `pauseSignaled` before
    /// entering `waitOpen()` — this ensures pauseForRecording() is called
    /// *after* the cancellable is registered but before the gate re-opens.
    ///
    /// Capture note: `queue` is captured strongly here for test scoping
    /// (the queue is discarded at the end of the test function). Production
    /// `makeStandard` uses `[weak queue]` to break the cycle.
    @Test("pauseForRecording cancels the inflight diarizer")
    func pauseCancelsDiarizer() async throws {
        actor DiarizerSpy: RefinementCancellable {
            var cancelled = false
            func cancel() { cancelled = true }
        }
        let spy = DiarizerSpy()
        let store = RefinementJobStore(directory: tempDir())
        let gate = PauseGate(initiallyOpen: true)
        let started = Gate()
        let pauseSignaled = Gate()    // test → runJob: "ok to proceed to waitOpen"

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in /* placeholder, replaced below */ },
            pauseGate: gate)
        await queue.setRunJob({ [queue] _ in
            await queue.setInflightCancellable(spy)
            await started.open()
            await pauseSignaled.wait()
            await gate.waitOpen()   // blocks until resume (won't happen in this test)
        })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"), recordingId: "rec_x",
            modelName: "base", modelSHA256: "deadbeef")
        await started.wait()

        // pauseForRecording must call cancel() on the registered spy.
        await queue.pauseForRecording()
        let wasCancelled = await spy.cancelled
        #expect(wasCancelled)

        // Cleanup: let runJob drain so the worker task doesn't outlive the test.
        await pauseSignaled.open()
        await queue.resumeAfterRecording()
    }

    /// `start()` prunes terminal jobs older than 30 days from the store before
    /// restoring active jobs. Terminal jobs younger than 30 days are kept.
    ///
    /// Seeds the store directly (bypassing the queue) with:
    /// - one 40-day-old `.completed` job  →  must be pruned
    /// - one  5-day-old `.completed` job  →  must survive
    /// Calls `start()` and asserts only the fresh job appears in `recent`.
    @Test("start() prunes terminal jobs older than 30 days")
    func startPrunesOldTerminalJobs() async throws {
        let dir = tempDir()
        let store = RefinementJobStore(directory: dir)
        let now = Date()

        let oldJob = RefinementJob(
            id: "job_old",
            recordingId: "rec_old",
            folderURL: URL(fileURLWithPath: "/tmp/old"),
            modelName: "base",
            modelSHA256: "deadbeef",
            trigger: .manual,
            enqueuedAt: now.addingTimeInterval(-40 * 86400),   // 40 days ago
            state: .completed(durationSeconds: 60, speakerCount: 2))
        let freshJob = RefinementJob(
            id: "job_fresh",
            recordingId: "rec_fresh",
            folderURL: URL(fileURLWithPath: "/tmp/fresh"),
            modelName: "base",
            modelSHA256: "deadbeef",
            trigger: .manual,
            enqueuedAt: now.addingTimeInterval(-5 * 86400),    //  5 days ago
            state: .completed(durationSeconds: 30, speakerCount: 1))

        try await store.upsert(oldJob)
        try await store.upsert(freshJob)

        // Create the queue and call start() — this triggers pruneTerminal(30).
        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in /* no-op — no active jobs */ })
        try await queue.start()

        let snap = await queue.snapshot()
        #expect(!snap.recent.contains { $0.id == "job_old" },
                "40-day-old job should have been pruned")
        #expect(snap.recent.contains { $0.id == "job_fresh" },
                "5-day-old job should still be present")
    }

    /// Two enqueued jobs run sequentially through the single-worker queue.
    /// Regression: the worker used to clear itself in a `defer` that ran
    /// *after* the tail `pumpIfIdle()`, leaving job 2 stranded.
    @Test("two enqueued jobs run sequentially")
    func runsTwoJobsSequentially() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let observed = Gate()    // open after both runs land
        actor Counter { var n = 0; func incr() -> Int { n += 1; return n } }
        let counter = Counter()

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in
                let after = await counter.incr()
                if after == 2 { await observed.open() }
            })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/a"),
            recordingId: "rec_a",
            modelName: "base", modelSHA256: "deadbeef")
        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/b"),
            recordingId: "rec_b",
            modelName: "base", modelSHA256: "deadbeef")

        await observed.wait()

        // Poll snapshot for terminal state (avoid the housekeeping race the
        // single-job test already documents).
        var snap = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !(snap.running == nil && snap.recent.count == 2) {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.running == nil)
        #expect(snap.queued.isEmpty)
        #expect(snap.recent.count == 2)
        let total = await counter.n
        #expect(total == 2)
    }

    @Test("reportStage awaits the disk upsert before returning")
    func reportStageAwaitsUpsert() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-rs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)

        // Hold the job in `running` indefinitely by parking the runJob
        // closure on a forever-closed gate. The actor stays reentrant
        // across the await, so external `reportStage` / `snapshot` calls
        // still process while the worker is parked.
        let holdOpen = PauseGate(initiallyOpen: false)
        let queue = RefinementJobQueue(
            store: store,
            runJob: { @Sendable _ in
                await holdOpen.waitOpen()  // suspends until the test ends
            },
            pauseGate: PauseGate(initiallyOpen: true))

        try await queue.enqueueAutoRefine(
            folderURL: dir, recordingId: "rec_rs",
            modelName: "stub", modelSHA256: "stub")

        // Wait for the worker to pick up the job (snapshot().running != nil).
        let deadline = Date().addingTimeInterval(1)
        while await queue.snapshot().running == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let running = await queue.snapshot().running else {
            Issue.record("worker never picked up the job"); return
        }

        let newState = RefinementJobState.running(
            stage: .diarizing, stepsCompleted: 2, stepsTotal: 7,
            regionIndex: nil, regionsTotal: nil)
        await queue.reportStage(newState)

        // Immediately read the on-disk job file — must reflect the new
        // state by the time reportStage returns.
        let jobFile = dir.appendingPathComponent("\(running.id).json")
        let data = try Data(contentsOf: jobFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(RefinementJob.self, from: data)
        if case .running(let stage, _, _, _, _) = onDisk.state {
            #expect(stage == .diarizing,
                    "reportStage must have awaited the upsert — on-disk stage was \(stage)")
        } else {
            Issue.record("on-disk state was not .running")
        }
    }

    @Test("pauseForRecording transforms a running job to .paused with lastStage")
    func pauseSetsPausedState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RefinementJobStore(directory: dir)
        let gate = PauseGate(initiallyOpen: true)

        // A runJob that reports a stage then suspends on the gate forever so
        // we can observe pauseForRecording while running.
        let queue = RefinementJobQueue(
            store: store,
            runJob: { @Sendable [gate] _ in
                await gate.waitOpen()
                // After the gate reopens, suspend forever (test cleanup
                // tears the actor down).
                try? await Task.sleep(for: .seconds(60))
            },
            pauseGate: gate)
        try await queue.enqueueAutoRefine(
            folderURL: dir, recordingId: "rec_pause",
            modelName: "stub", modelSHA256: "stub")
        // Manually mark the job's running state via reportStage so the
        // queue has a `lastStage` to capture.
        let deadline = Date().addingTimeInterval(1)
        while await queue.snapshot().running == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await queue.reportStage(.running(
            stage: .diarizing, stepsCompleted: 2, stepsTotal: 7,
            regionIndex: nil, regionsTotal: nil))

        await queue.pauseForRecording()
        let paused = await queue.snapshot().running
        guard case .paused(let reason, let lastStage) = paused?.state else {
            Issue.record("expected .paused, got \(String(describing: paused?.state))")
            return
        }
        #expect(reason == .recordingInProgress)
        #expect(lastStage == .diarizing)

        await queue.resumeAfterRecording()
        let resumed = await queue.snapshot().running
        guard case .running(let stage, _, _, _, _) = resumed?.state else {
            Issue.record("expected .running after resume, got \(String(describing: resumed?.state))")
            return
        }
        #expect(stage == .diarizing, "lastStage should round-trip through resume")
    }

    @Test("recent list is capped at 100 entries")
    func recentListCapped() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RefinementJobStore(directory: dir)
        // runJob completes instantly — no real refine.
        let queue = RefinementJobQueue(store: store, runJob: { _ in })

        // Enqueue 110 jobs, each with a unique recordingId so dedupe lets
        // them all in. Wait briefly between batches to let the worker pump.
        for i in 0..<110 {
            try await queue.enqueueManualRefine(
                folderURL: dir,
                recordingId: "rec_\(i)",
                modelName: "stub",
                modelSHA256: "stub")
        }
        // Give the single-worker pump time to drain. Poll snapshot until
        // queued is empty or 5s elapses.
        let deadline = Date().addingTimeInterval(5)
        while await queue.snapshot().queued.isEmpty == false,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let snap = await queue.snapshot()
        #expect(snap.queued.isEmpty, "queue did not drain in time")
        #expect(snap.recent.count <= 100,
                "recent should be capped at 100, got \(snap.recent.count)")
    }
}
