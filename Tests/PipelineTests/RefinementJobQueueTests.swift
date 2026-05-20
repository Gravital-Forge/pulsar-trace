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
