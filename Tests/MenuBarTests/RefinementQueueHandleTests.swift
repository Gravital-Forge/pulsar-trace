// Tests/MenuBarTests/RefinementQueueHandleTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// `RefinementQueueHandle` replaces the EnqueueBox/AsyncCallBox/QueueReadyGate
/// trio: enqueues that arrive before `install(_:)` suspend until bootstrap
/// installs the real queue; pause/resume before install are silent no-ops
/// (matching the old `self?.queue` optional-call behavior).
@Suite("RefinementQueueHandle")
@MainActor
struct RefinementQueueHandleTests {

    private func tempStore() -> RefinementJobStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-handle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RefinementJobStore(directory: dir)
    }

    /// A throwaway settings instance over a temp `UserDefaults` suite.
    private func tempSettings() -> (MenuBarSettings, cleanup: () -> Void) {
        let name = "pt-handle-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let settings = MenuBarSettings(defaults: defaults)
        return (settings, { defaults.removePersistentDomain(forName: name) })
    }

    /// Poll the queue until a terminal job for `recordingId` appears.
    private func waitForRecent(
        _ queue: RefinementJobQueue, recordingId: String
    ) async throws -> RefinementJob? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let s = await queue.snapshot()
            if let job = s.recent.first(where: { $0.recordingId == recordingId }) {
                return job
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test("enqueue before install suspends, then completes after install")
    func enqueueBeforeInstallSuspends() async throws {
        let (settings, cleanup) = tempSettings()
        defer { cleanup() }
        let handle = RefinementQueueHandle(settings: settings)

        let finished = MainActorBox<Bool>(value: false)
        let enqueue = Task { @MainActor in
            await handle.enqueueAutoRefine(
                folderURL: URL(fileURLWithPath: "/tmp/pre-install"),
                recordingId: "rec_pre")
            finished.value = true
        }
        // Give the enqueue task ample chance to run — it must be suspended
        // in awaitReady(), not completed.
        try await Task.sleep(for: .milliseconds(100))
        #expect(finished.value == false,
                "enqueue must suspend until the real queue is installed")

        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        handle.install(queue)
        await enqueue.value
        #expect(finished.value)

        let job = try await waitForRecent(queue, recordingId: "rec_pre")
        #expect(job != nil, "the pre-install enqueue must reach the queue")
    }

    @Test("pause and resume before install return immediately as no-ops")
    func pauseResumeBeforeInstallNoOp() async throws {
        let (settings, cleanup) = tempSettings()
        defer { cleanup() }
        let handle = RefinementQueueHandle(settings: settings)

        // Old AsyncCallBox impls read `self?.queue` and dropped the call when
        // nil — pause/resume must NOT wait for install. If this regressed to
        // awaiting readiness, both awaits below would suspend forever and the
        // test would time out.
        await handle.pauseForRecording()
        await handle.resumeAfterRecording()
        #expect(Bool(true), "reached without suspension — pre-install no-op holds")
    }

    @Test("install resumes every pending waiter")
    func installResumesAllWaiters() async throws {
        let (settings, cleanup) = tempSettings()
        defer { cleanup() }
        let handle = RefinementQueueHandle(settings: settings)

        let resumed = MainActorBox<Int>(value: 0)
        let waiters = (0..<3).map { _ in
            Task { @MainActor in
                await handle.awaitReady()
                resumed.value += 1
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(resumed.value == 0, "waiters must be suspended before install")

        handle.install(RefinementJobQueue(store: tempStore(), runJob: { _ in }))
        for w in waiters { await w.value }
        #expect(resumed.value == 3, "install must resume every pending waiter")

        // After install, awaitReady returns immediately.
        await handle.awaitReady()
    }

    @Test("enqueue after install goes straight through")
    func enqueueAfterInstall() async throws {
        let (settings, cleanup) = tempSettings()
        defer { cleanup() }
        let handle = RefinementQueueHandle(settings: settings)
        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        handle.install(queue)

        await handle.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/post-install"),
            recordingId: "rec_post")

        let job = try await waitForRecent(queue, recordingId: "rec_post")
        #expect(job != nil, "the post-install enqueue must reach the queue")
    }

    @Test("enqueue resolves the refine model from live settings at enqueue time")
    func enqueueResolvesModelFromLiveSettings() async throws {
        let (settings, cleanup) = tempSettings()
        defer { cleanup() }
        let handle = RefinementQueueHandle(settings: settings)
        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        handle.install(queue)

        // Changed AFTER the handle was created — the handle must read the
        // value at enqueue time, exactly like the old EnqueueBox impl.
        settings.refineModelName = WhisperKitModelCatalog.largeV3.name
        await handle.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/live-settings"),
            recordingId: "rec_live")
        let live = try await waitForRecent(queue, recordingId: "rec_live")
        #expect(live?.modelName == "large-v3-whisperkit")
        #expect(live?.modelSHA256 == "")   // CoreML bundles carry no pin (D39)

        // An unknown model name falls back to the catalog default.
        settings.refineModelName = "no-such-model"
        await handle.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/fallback"),
            recordingId: "rec_fallback")
        let fallback = try await waitForRecent(queue, recordingId: "rec_fallback")
        #expect(fallback?.modelName == "large-v3-turbo")
        #expect(fallback?.modelSHA256 == "")
    }

    @Test("pause and resume after install forward to the queue")
    func pauseResumeAfterInstallForward() async throws {
        let (settings, cleanup) = tempSettings()
        defer { cleanup() }
        let handle = RefinementQueueHandle(settings: settings)
        let queue = RefinementJobQueue(store: tempStore(), runJob: { _ in })
        handle.install(queue)

        await handle.pauseForRecording()
        #expect(await queue.snapshot().pausedForRecording)

        await handle.resumeAfterRecording()
        #expect(await queue.snapshot().pausedForRecording == false)
    }

    /// Captures values across `@MainActor` boundaries in a test.
    @MainActor private final class MainActorBox<T> {
        var value: T
        init(value: T) { self.value = value }
    }
}
