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
    public func setQueue(_ queue: RefinementJobQueue) async {
        self.queue = queue
        await refresh()
    }

    /// Re-read the queue once.
    public func refresh() async {
        let s = await queue.snapshot()
        running = s.running
        queued = s.queued
        recent = s.recent
        pausedForRecording = s.pausedForRecording
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

    /// Forward a "Refine" button press.
    public func enqueueManual(folderURL: URL, recordingId: String,
                              modelName: String, modelSHA256: String) async {
        try? await queue.enqueueManualRefine(
            folderURL: folderURL, recordingId: recordingId,
            modelName: modelName, modelSHA256: modelSHA256)
        await refresh()
    }

    public func cancel(recordingId: String) async {
        await queue.cancel(recordingId: recordingId)
        await refresh()
    }
}
