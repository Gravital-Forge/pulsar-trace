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
}
