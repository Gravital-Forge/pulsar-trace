// Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift
import Foundation
import PulsarTraceEngine

/// Main-actor `@Observable` façade over `RefinementJobQueue`. Views bind to
/// this; mutations forward into the actor.
///
/// The queue actor is the source of truth; this VM caches the last snapshot
/// and refreshes on a light timer. (A push channel via `AsyncStream` is a
/// cleaner long-term answer — the live-watcher polling pattern in
/// `LiveTranscriptWatcher` works fine for v1.)
@MainActor
@Observable
public final class RefinementJobQueueViewModel {

    public private(set) var running: RefinementJob?
    public private(set) var queued: [RefinementJob] = []
    public private(set) var recent: [RefinementJob] = []
    public private(set) var pausedForRecording = false

    /// Last enqueue error, if any. The recordings list surfaces this as a
    /// short alert string; it is cleared by the next successful enqueue.
    public var lastEnqueueError: String?

    /// Called once per `refresh()` tick with every refinement job that
    /// transitioned into a terminal state (completed / failed / cancelled)
    /// since the previous tick. Set by `AppEnvironment` to a closure that
    /// re-scans the recordings list so a freshly-refined recording flips
    /// from "Not yet refined" to the speaker/duration line without a manual
    /// Refresh.
    ///
    /// Batched (per-tick, not per-job) so a burst drain — N terminations in
    /// one 250 ms poll — triggers exactly one consumer-side reaction rather
    /// than N parallel ones.
    public var onJobsTerminated: (@MainActor @Sendable ([RefinementJob]) -> Void)?

    private var seenRecentIDs: Set<String> = []

    private var queue: RefinementJobQueue
    private var poller: Task<Void, Never>?

    public init(queue: RefinementJobQueue) {
        self.queue = queue
    }

    /// Swap in the real queue once it has been built asynchronously (E2).
    ///
    /// `AppEnvironment` initialises `queueVM` with a placeholder queue and
    /// calls this from `bootstrap()` once `makeStandard` completes, so the
    /// environment object is always non-optional.
    ///
    /// Primes `seenRecentIDs` from the queue's persisted terminal jobs
    /// before any callback could possibly fire, so `onJobsTerminated` is
    /// NOT invoked for jobs that completed before this VM was wired up.
    /// Doing this inside `setQueue` (instead of relying on `onJobsTerminated`
    /// happening to still be `nil` at the call site) makes the invariant
    /// structural — a future refactor that hoists callback assignment above
    /// `setQueue` in `bootstrap()` cannot regress it.
    public func setQueue(_ newQueue: RefinementJobQueue) async {
        self.queue = newQueue
        let s = await newQueue.snapshot()
        running = s.running
        queued = s.queued
        recent = s.recent
        seenRecentIDs = Set(s.recent.map { $0.id })
        pausedForRecording = s.pausedForRecording
    }

    /// Re-read the queue once. Fires `onJobsTerminated` at most once per
    /// tick, with every job that became terminal since the previous tick.
    public func refresh() async {
        let s = await queue.snapshot()
        running = s.running
        queued = s.queued
        // Diff against the prior tick's terminal-id set so each completion
        // surfaces exactly once. `seenRecentIDs` is reseeded from `s.recent`
        // (capped at 100 by the queue), so it cannot grow unbounded.
        let newlyTerminated = s.recent.filter { !seenRecentIDs.contains($0.id) }
        recent = s.recent
        seenRecentIDs = Set(s.recent.map { $0.id })
        pausedForRecording = s.pausedForRecording
        if !newlyTerminated.isEmpty {
            onJobsTerminated?(newlyTerminated)
        }
    }

    deinit {
        MainActor.assumeIsolated { poller?.cancel() }
    }

    /// Start a light poll (250 ms) so the UI updates without a push channel.
    /// Cancelled when the VM is deinited or `stopPolling()` is called.
    public func startPolling() {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    public func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// Replace any occurrence of the user's home directory with `~`, so a
    /// rendered error string doesn't leak `/Users/<name>/...` into the UI.
    /// The redaction matches the convention in `ResumableRefiner.redactPath`.
    static func redactHome(_ s: String) -> String {
        s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Forward a "Refine" button press.
    public func enqueueManual(folderURL: URL, recordingId: String,
                              modelName: String, modelSHA256: String) async {
        do {
            try await queue.enqueueManualRefine(
                folderURL: folderURL, recordingId: recordingId,
                modelName: modelName, modelSHA256: modelSHA256)
            lastEnqueueError = nil
        } catch {
            lastEnqueueError = Self.redactHome("Could not enqueue refinement: \(error)")
        }
        await refresh()
    }

    public func cancel(recordingId: String) async {
        await queue.cancel(recordingId: recordingId)
        await refresh()
    }
}
