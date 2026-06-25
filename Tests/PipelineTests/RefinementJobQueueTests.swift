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
    /// cancellable (D-Q7 / Task PT-P1-D3). A spy actor records whether it was hit.
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

    /// `pauseForRecording` fires the registered transcriber-release hook so
    /// the resident WhisperKit transcriber drops its CoreML models (ARC frees
    /// them) before the live pass loads its own model, so the two passes don't
    /// contend for ANE/memory at recording start. The hook is set/cleared by
    /// the worker; the queue invokes it inside `pauseForRecording` after
    /// cancelling the diarizer.
    @Test("pauseForRecording fires the transcriber-release hook")
    func pauseFiresTranscriberRelease() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let gate = PauseGate(initiallyOpen: true)
        let started = Gate()
        let pauseSignaled = Gate()    // test → runJob: "ok to proceed"
        let releaseCounter = ReleaseCounter()

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in /* placeholder, replaced below */ },
            pauseGate: gate)
        await queue.setRunJob({ [queue] _ in
            await queue.setInflightTranscriberRelease {
                releaseCounter.increment()
            }
            await started.open()
            await pauseSignaled.wait()
            await gate.waitOpen()
        })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_release", modelName: "base",
            modelSHA256: "deadbeef")
        await started.wait()

        // The hook is registered now. pauseForRecording must invoke it.
        // We start the pause-call in a task so we can unblock the
        // runJob's `pauseSignaled` wait and let the worker exit (the
        // hook in this test doesn't actually unwedge a real
        // transcriber, so the worker stays parked until we let it go).
        async let pauseDone: Void = queue.pauseForRecording()
        // Give pauseForRecording() a turn to fire the release hook.
        // The release counter is incremented synchronously inside the
        // hook closure, so polling here is deterministic.
        let deadline = ContinuousClock.now + .seconds(2)
        while releaseCounter.value() == 0,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releaseCounter.value() == 1,
                "pauseForRecording must fire the release hook exactly once")

        // Unblock the parked runJob so the worker can exit; the
        // pauseForRecording call has a 5s worker-exit timeout, but with
        // the runJob now able to proceed we'll let it complete cleanly.
        await pauseSignaled.open()
        await queue.resumeAfterRecording()
        await pauseDone
    }

    /// A small thread-safe counter — the release hook closure is
    /// `@Sendable`-typed in the queue API, so we can't capture an actor
    /// directly. Using `NSLock` + a class is the path of least
    /// resistance and matches the `SharedTranscriberBox` pattern.
    final class ReleaseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
        func value() -> Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// Post-cutover contract (PT-P5-D1): `pauseForRecording` returns within its
    /// bounded wait, and only after the worker task has exited, when the
    /// release hook *cancels an in-flight decode* — the production shape.
    ///
    /// This pins the new mechanism rather than the old subprocess one. The
    /// spy "transcribe" inside `runJob` BLOCKS until a cancel flag is set
    /// (mirroring a real `WhisperKitRegionTranscriber.decode` parked inside
    /// `pipe.transcribe`), and then throws `CancellationError` (mirroring the
    /// per-token callback returning `false` → `decode` throwing). The release
    /// hook flips that cancel flag — it does NOT make the worker exit
    /// voluntarily. The throw propagates out of the worker, which is what
    /// lets `pauseForRecording` complete.
    ///
    /// If `pauseForRecording`'s wait were still the broken `withTaskGroup`
    /// race (drains all children; can't time out) OR the release hook didn't
    /// actually cancel the decode, this test would hang past its bound.
    ///
    /// Recovery-contract assertions (Fix 1): the cancel via the release hook
    /// must complete *well inside* the 5 s timeout (proving the worker exited
    /// because the decode was cancelled, NOT because the timeout escape fired),
    /// and the cancelled job must land back as `.queued` at the head of the
    /// queue — NOT `.failed`, and NOT in `recent` as a failure. The on-disk
    /// checkpoint stays addressable by the unchanged job id.
    @Test("pauseForRecording cancels the in-flight decode and requeues the job")
    func pauseCancelsDecodeAndAwaitsWorkerExit() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let gate = PauseGate(initiallyOpen: true)
        let started = Gate()

        // A sticky cancel flag the release hook fires and the spy decode
        // observes — the test-double analogue of `CancelFlag` inside
        // `WhisperKitRegionTranscriber`. NSLock-backed for cross-isolation.
        final class CancelSpy: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func fire() { lock.lock(); defer { lock.unlock() }; fired = true }
            func didFire() -> Bool { lock.lock(); defer { lock.unlock() }; return fired }
        }
        let cancel = CancelSpy()
        let workerExited = Gate()

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in /* placeholder */ },
            pauseGate: gate)
        await queue.setRunJob({ [queue] _ in
            // The release hook cancels the in-flight decode (it does not make
            // the worker exit on its own) — exactly what the production hook
            // does via `box.peek()?.cancelPending()`.
            await queue.setInflightTranscriberRelease { cancel.fire() }
            await started.open()
            defer { Task { await workerExited.open() } }
            // Simulate a decode parked inside `pipe.transcribe`: block until
            // cancelled, then throw `CancellationError` like `decode` does
            // once its callback returns `false`. The throw unwinds the worker.
            while !cancel.didFire() {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()   // propagate out of the worker
        })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_await", modelName: "base",
            modelSHA256: "deadbeef")
        await started.wait()
        let runningId = try #require(await queue.snapshot().running?.id)

        // pauseForRecording must return within its bound. Race it against a
        // generous watchdog so a regression to the old unbounded behaviour
        // fails the test instead of hanging the suite. Measure elapsed so we
        // can assert the cancel path (not the 5 s timeout escape) is what
        // returned.
        let pauseStart = ContinuousClock.now
        let returnedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await queue.pauseForRecording(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let pauseElapsed = ContinuousClock.now - pauseStart
        #expect(returnedInTime,
                "pauseForRecording did not return within its bounded wait")
        // The cancel must unwind the worker; the 5 s poll is an escape hatch,
        // not the normal path. Returning in < 5 s proves the worker exited via
        // the cancel, not the timeout.
        #expect(pauseElapsed < .seconds(5),
                "pause returned via the timeout escape, not the decode cancel (\(pauseElapsed))")
        #expect(cancel.didFire(), "release hook must have cancelled the decode")
        await workerExited.wait()

        // Recovery contract: the worker has exited, no job is running, and the
        // cancelled job requeued (same id, .queued) at the head — it did NOT
        // fail and is NOT in `recent`.
        // Poll briefly: runNext's requeue housekeeping lands after the worker
        // task's body returns, which may trail `workerExited`.
        var snap = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !(snap.running == nil && snap.queued.contains { $0.id == runningId }) {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.running == nil)
        let requeued = try #require(
            snap.queued.first { $0.id == runningId },
            "cancelled job must requeue with the SAME id, not a fresh one")
        #expect(requeued.state == .queued,
                "requeued job must be .queued, not .failed — got \(requeued.state)")
        #expect(!snap.recent.contains { $0.id == runningId },
                "a pause-cancelled job must NOT appear in recent as a failure")
    }

    /// Deadlock pin (Fix 4a). A `runJob` that registers a release hook,
    /// IGNORES it, and blocks indefinitely (never exits) must still let
    /// `pauseForRecording` return — via the bounded 5 s worker-exit poll. The
    /// old `withTaskGroup`-racing-a-sleep code drained all children before
    /// returning and so would HANG this test forever; the poll-on-actor-state
    /// rewrite bounds it.
    ///
    /// Gated by a generous watchdog so a regression fails (records a violation
    /// + `#expect(false)`) instead of wedging the whole suite.
    @Test("pauseForRecording returns even if the worker ignores the release hook")
    func pauseReturnsWhenWorkerIgnoresRelease() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let gate = PauseGate(initiallyOpen: true)
        let started = Gate()
        let release = ReleaseCounter()

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in /* placeholder */ },
            pauseGate: gate)
        await queue.setRunJob({ [queue] _ in
            // Register a hook (so pauseForRecording arms its worker-exit wait)
            // but the body deliberately never observes it — it blocks forever.
            await queue.setInflightTranscriberRelease { release.increment() }
            await started.open()
            // Block indefinitely, ignoring the release entirely. The 5 s poll
            // must give up and let pauseForRecording return regardless.
            while true {
                try? await Task.sleep(for: .seconds(60))
            }
        })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_wedge", modelName: "base",
            modelSHA256: "deadbeef")
        await started.wait()

        // Race pauseForRecording against a 10 s watchdog. The bounded poll is
        // 5 s; if pauseForRecording returns we win. If the old TaskGroup code
        // regressed (hangs forever) the watchdog wins and we fail loudly.
        let pauseStart = ContinuousClock.now
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await queue.pauseForRecording(); return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false   // watchdog: a regression hangs past the 5 s poll
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let elapsed = ContinuousClock.now - pauseStart
        if !returned {
            Issue.record("pauseForRecording HUNG — the bounded worker-exit poll regressed")
        }
        #expect(returned, "pauseForRecording must return even when the worker ignores the release")
        #expect(elapsed < .seconds(6),
                "pause should return at the ~5 s poll bound, took \(elapsed)")
        #expect(release.value() == 1, "the release hook is still fired exactly once")

        // The worker is still wedged; let it leak (the test process tears down).
        // No further assertions — this test pins the timeout escape only.
    }

    /// Resume after a pause-cancel (Fix 4c). After the pause cancels the
    /// in-flight decode and the job requeues, `resumeAfterRecording` must
    /// re-run that SAME job (same id — so the on-disk checkpoint is honored)
    /// and let it complete. The spy decode fails (cancels) the first time and
    /// succeeds the second.
    @Test("resumeAfterRecording re-runs the requeued job to completion with the same id")
    func resumeRerunsRequeuedJob() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let gate = PauseGate(initiallyOpen: true)
        let started = Gate()
        let completed = Gate()

        // Sticky cancel flag (first attempt) and an attempt counter so the
        // second run succeeds.
        final class CancelSpy: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func fire() { lock.lock(); defer { lock.unlock() }; fired = true }
            func didFire() -> Bool { lock.lock(); defer { lock.unlock() }; return fired }
        }
        let cancel = CancelSpy()
        actor Attempts { var n = 0; func next() -> Int { n += 1; return n } }
        let attempts = Attempts()

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in /* placeholder */ },
            pauseGate: gate)
        await queue.setRunJob({ [queue] _ in
            let attempt = await attempts.next()
            if attempt == 1 {
                // First run: behave like a decode parked inside transcribe,
                // cancelled by the release hook → throw CancellationError.
                await queue.setInflightTranscriberRelease { cancel.fire() }
                await started.open()
                while !cancel.didFire() {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw CancellationError()
            } else {
                // Second run (after resume): the decode succeeds.
                await completed.open()
            }
        })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_resume", modelName: "base",
            modelSHA256: "deadbeef")
        await started.wait()
        let originalId = try #require(await queue.snapshot().running?.id)

        // Pause: cancels the decode, requeues the job (same id, .queued).
        await queue.pauseForRecording()

        // Poll until the job is requeued (housekeeping trails the worker exit).
        var snap = await queue.snapshot()
        var deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline,
              !(snap.running == nil && snap.queued.contains { $0.id == originalId }) {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.queued.contains { $0.id == originalId },
                "job must be requeued before resume")

        // Resume: re-runs the requeued job; the second attempt completes.
        await queue.resumeAfterRecording()
        await completed.wait()

        // The job ran a second time and reached terminal completion. Its id is
        // unchanged — the checkpoint on disk would have been honored.
        snap = await queue.snapshot()
        deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !(snap.running == nil && snap.recent.contains { $0.id == originalId }) {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.running == nil)
        let finished = try #require(
            snap.recent.first { $0.id == originalId },
            "the requeued job (same id) must reach terminal state after resume")
        if case .completed = finished.state {
            // expected
        } else {
            Issue.record("expected .completed for the resumed job, got \(finished.state)")
        }
        let total = await attempts.n
        #expect(total == 2, "the job must have run exactly twice (cancel, then success)")
    }

    /// Fix I1: a pause that lands in a NON-decode window (VAD / WAV-load /
    /// parked-between-regions — no in-flight decode) must STILL requeue the job,
    /// not fail it. In that window the release hook's `cancelPending()` is a
    /// no-op, but `box.release()` POISONS the box, so the worker does not unwind
    /// during `pauseForRecording` (its `waitOpen()` parks, it does not throw).
    /// The worker exits only LATER — at its next `box.get()` AFTER
    /// `resumeAfterRecording` — and by then `pausedForRecording` is already
    /// `false`. The requeue arm must therefore match `CancellationError`
    /// UNCONDITIONALLY; before Fix I1 it gated on `pausedForRecording` and so
    /// misclassified this interleave to `.transcribeFailed` (spurious UI failure,
    /// stranded checkpoint).
    ///
    /// Spy shape (mirrors the failure trace, not the production decode path):
    /// 1. registers a release hook that only flips a flag — it does NOT make the
    ///    worker exit (simulating "no in-flight decode to cancel"),
    /// 2. parks on a manual `resumed` signal (simulating `waitOpen()` parking),
    /// 3. after resume, throws `CancellationError` (simulating the next
    ///    `box.get()` throwing off the poisoned box).
    ///
    /// Timing note: with no in-flight decode to cancel, `pauseForRecording`
    /// cannot observe the worker exit and returns via its ~5 s worker-exit poll
    /// (the bound is a constant in the queue — not injectable — so this test
    /// takes ~5 s; acceptable for a pipeline suite). The first assertion below
    /// only runs after that wait elapses.
    @Test("pause in a non-decode window requeues the job, does not fail it")
    func pauseInNonDecodeWindowRequeues() async throws {
        let store = RefinementJobStore(directory: tempDir())
        let gate = PauseGate(initiallyOpen: true)
        let started = Gate()        // runJob (first attempt) is executing
        let resumed = Gate()        // test → runJob: resume happened, now throw
        let completed = Gate()      // second attempt reached completion

        actor Attempts { var n = 0; func next() -> Int { n += 1; return n } }
        let attempts = Attempts()

        let queue = RefinementJobQueue(
            store: store,
            runJob: { _ in /* placeholder */ },
            pauseGate: gate)
        await queue.setRunJob({ [queue] _ in
            let attempt = await attempts.next()
            if attempt == 1 {
                // Register a release hook that merely flips a flag — it does NOT
                // unwind the worker. This is the "no in-flight decode" case:
                // `cancelPending()` would be a no-op; only `box.release()` (the
                // box-poison) matters, simulated by the post-resume throw below.
                await queue.setInflightTranscriberRelease { /* no worker exit */ }
                await started.open()
                // Park like `pauseGate.waitOpen()` would — does NOT throw on the
                // pause. The worker stays here through the whole
                // pauseForRecording 5 s poll.
                await resumed.wait()
                // After resume, the next `box.get()` throws off the poisoned box.
                throw CancellationError()
            } else {
                // Second attempt (after requeue + resume re-pump): completes.
                await completed.open()
            }
        })
        try await queue.start()

        try await queue.enqueueManualRefine(
            folderURL: URL(fileURLWithPath: "/tmp/x"),
            recordingId: "rec_nondecode", modelName: "base",
            modelSHA256: "deadbeef")
        await started.wait()
        let originalId = try #require(await queue.snapshot().running?.id)

        // Pause: no decode to cancel, so this returns via the ~5 s worker-exit
        // poll (the worker is parked on `resumed`, hasn't thrown yet).
        await queue.pauseForRecording()

        // The worker has not thrown yet — it is still the running job, paused.
        let paused = await queue.snapshot()
        #expect(paused.running?.id == originalId,
                "worker must still be parked (not yet unwound) after the pause")
        #expect(paused.pausedForRecording == true)

        // Resume FIRST (clears pausedForRecording), THEN release the worker so it
        // throws CancellationError — reproducing the resume-then-throw interleave
        // where the flag is already false when the requeue arm runs.
        await queue.resumeAfterRecording()
        await resumed.open()

        // The requeue arm (matching CancellationError unconditionally) must put
        // the SAME job back as `.queued`, not `.failed`, not in `recent`, and
        // then `pumpIfIdle` (guard now passes — not paused) must re-run it.
        await completed.wait()

        var snap = await queue.snapshot()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline,
              !(snap.running == nil && snap.recent.contains { $0.id == originalId }) {
            try await Task.sleep(for: .milliseconds(5))
            snap = await queue.snapshot()
        }
        #expect(snap.running == nil)
        // The cancelled first attempt never produced a failure entry.
        #expect(!snap.recent.contains {
            $0.id == originalId && {
                if case .failed = $0.state { return true } else { return false }
            }($0)
        }, "a non-decode-window pause-cancel must NOT produce a .failed entry")
        let finished = try #require(
            snap.recent.first { $0.id == originalId },
            "the requeued job (same id) must reach terminal completion after resume")
        if case .completed = finished.state {
            // expected
        } else {
            Issue.record("expected .completed for the resumed job, got \(finished.state)")
        }
        let total = await attempts.n
        #expect(total == 2,
                "job must run exactly twice: cancelled in non-decode window, then re-run")
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
