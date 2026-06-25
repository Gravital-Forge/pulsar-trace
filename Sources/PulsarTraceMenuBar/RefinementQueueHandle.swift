// Sources/PulsarTraceMenuBar/RefinementQueueHandle.swift
import Foundation
import PulsarTraceEngine

/// Hands the recording flow a queue that doesn't exist yet.
///
/// `RecordingViewModel` needs enqueue/pause/resume closures at init time,
/// but the real `RefinementJobQueue` is built asynchronously during
/// bootstrap. This handle is created first, captured by those closures,
/// and later `install(_:)`-ed with the real queue; enqueues arriving
/// before that suspend in `awaitReady()`. Replaces the trio of anonymous
/// boxes (EnqueueBox/AsyncCallBox/QueueReadyGate) with one named seam.
@MainActor
final class RefinementQueueHandle {

    /// The real queue, once `bootstrap()` has built it. `nil` until then.
    private var queue: RefinementJobQueue?
    /// Enqueues suspended in `awaitReady()` while `queue` is still `nil`.
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReady = false

    /// Read at enqueue time for the refine model name — the user can change
    /// the model between recordings, so it must not be captured up-front.
    private let settings: MenuBarSettings

    init(settings: MenuBarSettings) {
        self.settings = settings
    }

    /// Install the real queue and resume every suspended enqueue. Idempotent
    /// in effect: later calls just swap the queue (no waiters remain).
    func install(_ queue: RefinementJobQueue) {
        self.queue = queue
        isReady = true
        let waiters = readyWaiters
        readyWaiters = []
        for w in waiters { w.resume() }
    }

    /// Suspend until `install(_:)` has run; returns immediately afterwards.
    func awaitReady() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// Enqueue-after-record: WAITS for bootstrap (matches the old
    /// EnqueueBox + QueueReadyGate behavior), so a stop-recording that lands
    /// during bootstrap still gets its auto-refine enqueued instead of
    /// silently dropping. The refine model is resolved from live settings at
    /// enqueue time; an enqueue failure is logged to stderr (home-redacted),
    /// never thrown at the recording flow.
    func enqueueAutoRefine(folderURL: URL, recordingId: String) async {
        await awaitReady()
        guard let queue else {
            // Unreachable after a normal install — kept as the same guard the
            // old box impl had for "queue gone after bootstrap".
            FileHandle.standardError.write(
                Data("pulsartrace-mac: auto-refine dropped — queue gone after bootstrap\n".utf8))
            return
        }
        let model = WhisperKitModelCatalog.model(named: settings.refineModelName)
            ?? WhisperKitModelCatalog.defaultModel
        do {
            try await queue.enqueueAutoRefine(
                folderURL: folderURL, recordingId: recordingId,
                modelName: model.name,
                modelSHA256: "")   // SDK-managed CoreML bundle (D39)
        } catch {
            let raw = "pulsartrace-mac: auto-refine enqueue failed: \(error)\n"
            let msg = PathRedactor.redactHome(raw)
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    /// Pause: NO-OP before bootstrap (matches the old AsyncCallBox impls
    /// that read `self?.queue` and dropped the call when nil) — a recording
    /// started before the queue exists has nothing to pause.
    func pauseForRecording() async {
        guard isReady, let queue else { return }
        await queue.pauseForRecording()
    }

    /// Resume: NO-OP before bootstrap, same rationale as `pauseForRecording`.
    func resumeAfterRecording() async {
        guard isReady, let queue else { return }
        await queue.resumeAfterRecording()
    }
}
