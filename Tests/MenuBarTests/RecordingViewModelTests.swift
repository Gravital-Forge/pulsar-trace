import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// `RecordingViewModel`'s status machine (R40, R45), exercised through
/// the injected orchestration seam so no real capture/engine processes spawn.
@Suite("RecordingViewModel")
@MainActor
struct RecordingViewModelTests {

    // MARK: - Stub orchestrator

    /// A controllable `RecordingOrchestrating` stub. `start` succeeds or throws
    /// per `startError`; `waitForEngineExit` blocks until `signalEngineExit()`
    /// is called, letting a test drive a crash or a clean stop deterministically.
    final class StubOrchestrator: RecordingOrchestrating, @unchecked Sendable {
        let startError: Error?
        private let exitGate = Gate()
        private(set) var stopped = false
        private(set) var startCalled = false

        init(startError: Error? = nil) {
            self.startError = startError
        }

        func start(readyTimeout: Duration) async throws {
            startCalled = true
            if let startError { throw startError }
        }

        func waitForEngineExit() async {
            await exitGate.wait()
        }

        func isEngineRunning() async -> Bool {
            await !exitGate.isOpen()
        }

        func stop() async {
            stopped = true
            await exitGate.open()
        }

        /// Simulate an unexpected engine exit (a crash).
        func signalEngineExit() async {
            await exitGate.open()
        }

        /// A one-shot open/wait gate.
        actor Gate {
            private var opened = false
            private var waiters: [CheckedContinuation<Void, Never>] = []
            func open() {
                guard !opened else { return }
                opened = true
                for w in waiters { w.resume() }
                waiters.removeAll()
            }
            func isOpen() -> Bool { opened }
            func wait() async {
                if opened { return }
                await withCheckedContinuation { waiters.append($0) }
            }
        }
    }

    // MARK: - Helpers

    /// A `MenuBarSettings` with a real, resolvable output folder.
    private func settings(outputRoot: URL) throws -> MenuBarSettings {
        let defaults = UserDefaults(suiteName: "pt-rvm-\(UUID().uuidString)")!
        let settings = MenuBarSettings(defaults: defaults)
        settings.outputFolderPath = outputRoot.path
        return settings
    }

    /// Build a VM around a given stub orchestrator and a no-op enqueue closure.
    /// `preflight: .granted` — unit tests must never hit real TCC prompts.
    private func makeVM(
        settings: MenuBarSettings,
        orchestrator: StubOrchestrator
    ) -> RecordingViewModel {
        RecordingViewModel(
            settings: settings,
            orchestratorFactory: { _, _ in orchestrator },
            preflight: .granted)
    }

    // MARK: - Tests

    @Test("happy path: idle → recording → idle, refine is enqueued not run inline")
    func happyPathTransitions() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let enqueued = EnqueueMailbox()

        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            enqueueAutoRefine: { url, recordingId in
                await enqueued.record(url: url, recordingId: recordingId)
            },
            preflight: .granted)

        #expect(vm.status == .idle)
        await vm.startRecording()
        if case .recording = vm.status {} else { Issue.record("not recording") }

        await vm.stopRecording()
        #expect(vm.status == .idle)

        let recorded = await enqueued.entries
        #expect(recorded.count == 1)
        #expect(recorded.first?.recordingId.hasPrefix("rec_") == true)
    }

    @Test("an unexpected engine exit while recording moves to .crashed")
    func unexpectedEngineExitCrashes() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let vm = makeVM(settings: try settings(outputRoot: root), orchestrator: stub)

        await vm.startRecording()
        guard case .recording = vm.status else {
            Issue.record("expected .recording")
            return
        }

        // The engine dies on its own — the crash watch should fire.
        await stub.signalEngineExit()
        // Give the crash-watch task a turn to run.
        for _ in 0..<50 {
            if case .crashed = vm.status { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard case .crashed(_, let partial) = vm.status else {
            Issue.record("expected .crashed, got \(vm.status)")
            return
        }
        #expect(partial != nil)
    }

    @Test("a second start while not idle is rejected")
    func secondStartRejected() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let vm = makeVM(settings: try settings(outputRoot: root), orchestrator: stub)

        await vm.startRecording()
        guard case .recording(let id, let started) = vm.status else {
            Issue.record("expected .recording")
            return
        }
        // A second start must be a no-op — the state is unchanged.
        await vm.startRecording()
        #expect(vm.status == .recording(id: id, startedAt: started))
    }

    @Test("a start failure surfaces as .error")
    func startFailureSurfacesError() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator(
            startError: RecordOrchestrator.StartError.readyTimedOut)
        let vm = makeVM(settings: try settings(outputRoot: root), orchestrator: stub)

        await vm.startRecording()
        guard case .error = vm.status else {
            Issue.record("expected .error, got \(vm.status)")
            return
        }
        vm.dismissCrash()
        #expect(vm.status == .idle)
    }

    // Replaces the old "starting with no output folder surfaces .error" test:
    // `outputFolderURL` now defaults to `~/Documents/PulsarTrace`, so a fresh
    // settings can no longer trip the missing-folder guard. The defensive
    // folder-creation error path is covered instead.
    @Test("an uncreatable recording folder surfaces .error (defensive path)")
    func uncreatableOutputFolderError() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // The configured output root nests under a regular *file*, so the
        // per-recording folder cannot be created.
        let file = root.appendingPathComponent("not-a-dir")
        try Data().write(to: file)
        let settings = try settings(
            outputRoot: file.appendingPathComponent("nested"))
        let vm = makeVM(settings: settings, orchestrator: StubOrchestrator())

        await vm.startRecording()
        guard case .error(let message) = vm.status else {
            Issue.record("expected .error, got \(vm.status)")
            return
        }
        #expect(message.contains("Cannot create the recording folder"))
    }

    @Test("recoverFromCrash enqueues the partial folder and returns to idle")
    func recoverFromCrashRefines() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()

        let enqueued = EnqueueMailbox()
        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            enqueueAutoRefine: { url, recordingId in
                await enqueued.record(url: url, recordingId: recordingId)
            },
            preflight: .granted)

        await vm.startRecording()
        await stub.signalEngineExit()
        for _ in 0..<50 {
            if case .crashed = vm.status { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard case .crashed = vm.status else {
            Issue.record("expected .crashed")
            return
        }

        await vm.recoverFromCrash()
        #expect(vm.status == .idle)
        #expect(await enqueued.entries.count == 1)
    }

    // MARK: - FIX 1 / FIX 4

    @Test("liveMarkdownURL is set during recording and cleared after (FIX 1)")
    func liveMarkdownURLLifecycle() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            preflight: .granted)

        #expect(vm.liveMarkdownURL == nil)

        await vm.startRecording()
        let liveURL = try #require(vm.liveMarkdownURL)
        // It points at `live.md` inside the recording folder under the root.
        #expect(liveURL.lastPathComponent == "live.md")
        #expect(liveURL.deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL
            == root.standardizedFileURL)

        await vm.stopRecording()
        #expect(vm.liveMarkdownURL == nil)
    }

    @Test("liveMarkdownURL is cleared when the engine crashes (FIX 1)")
    func liveMarkdownURLClearedOnCrash() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let vm = makeVM(settings: try settings(outputRoot: root), orchestrator: stub)

        await vm.startRecording()
        #expect(vm.liveMarkdownURL != nil)

        await stub.signalEngineExit()
        for _ in 0..<50 {
            if case .crashed = vm.status { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard case .crashed = vm.status else {
            Issue.record("expected .crashed")
            return
        }
        #expect(vm.liveMarkdownURL == nil)
    }

    @Test("the live pass receives liveModelName, enqueue is called after stop (FIX 4)")
    func liveAndRefineModelsAreSeparate() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = try settings(outputRoot: root)
        settings.liveModelName = "base"
        settings.refineModelName = "large-v3"

        // Capture the RecordPlan the live pass is launched with.
        let planBox = PlanMailbox()
        let enqueued = EnqueueMailbox()
        let stub = StubOrchestrator()
        let vm = RecordingViewModel(
            settings: settings,
            orchestratorFactory: { plan, _ in
                Task { await planBox.set(plan) }
                return stub
            },
            // Assert the VM hands the live pass `liveModelName` via the plan
            // and that the enqueue path is taken after stop.
            enqueueAutoRefine: { url, recordingId in
                await enqueued.record(url: url, recordingId: recordingId)
            },
            preflight: .granted)

        await vm.startRecording()
        let plan = try #require(await planBox.value())
        // The live pass's argv carries `--model base` (liveModelName), not
        // `large-v3` (which is the refine model).
        #expect(plan.captureArguments.contains("base"))
        #expect(!plan.captureArguments.contains("large-v3"))
        #expect(plan.engineArguments.contains("base"))

        await vm.stopRecording()
        #expect(await enqueued.entries.count == 1)
    }

    // MARK: - Pause / resume hooks (Bug 1)

    @Test("pause is called on successful start, resume is NOT called")
    func pauseCalledOnStart() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let counter = CallCounter()

        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            pauseRefinement: { await counter.incrementPause() },
            resumeRefinement: { await counter.incrementResume() },
            preflight: .granted)

        await vm.startRecording()
        if case .recording = vm.status {} else { Issue.record("expected .recording") }
        #expect(await counter.pauseCount == 1)
        #expect(await counter.resumeCount == 0)
    }

    @Test("resume is called exactly once after stop")
    func resumeCalledOnStop() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let counter = CallCounter()

        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            pauseRefinement: { await counter.incrementPause() },
            resumeRefinement: { await counter.incrementResume() },
            preflight: .granted)

        await vm.startRecording()
        await vm.stopRecording()
        #expect(vm.status == .idle)
        #expect(await counter.pauseCount == 1)
        #expect(await counter.resumeCount == 1)
    }

    @Test("pause and resume both called on start failure, status is .error")
    func pauseAndResumeOnStartFailure() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator(
            startError: RecordOrchestrator.StartError.readyTimedOut)
        let counter = CallCounter()

        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            pauseRefinement: { await counter.incrementPause() },
            resumeRefinement: { await counter.incrementResume() },
            preflight: .granted)

        await vm.startRecording()
        guard case .error = vm.status else {
            Issue.record("expected .error, got \(vm.status)")
            return
        }
        #expect(await counter.pauseCount == 1)
        #expect(await counter.resumeCount == 1)
    }

    // MARK: - Phase 6: whisper-lock probe (Layer B)

    /// A lock-probe timeout error used to drive the failure path in tests
    /// — same shape `WhisperLockProbe.ProbeError.timeout` produces in
    /// production, but defined here so the menubar test target doesn't
    /// need internal access to that enum.
    private struct ProbeTimeoutError: Error {}

    @Test("lock-probe timeout surfaces .error and resumes refinement")
    func lockProbeTimeoutSurfacesError() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let counter = CallCounter()

        // Inject a probe closure that always throws (simulating the
        // refinement-whisper subprocess still holding the binary lock
        // past the 5s deadline). Phase 6 / Layer B: the VM must
        // surface a user-facing error and resume the refinement queue.
        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            pauseRefinement: { await counter.incrementPause() },
            resumeRefinement: { await counter.incrementResume() },
            waitForWhisperLockFree: { throw ProbeTimeoutError() },
            preflight: .granted)

        await vm.startRecording()
        guard case .error(let message) = vm.status else {
            Issue.record("expected .error, got \(vm.status)")
            return
        }
        // The user-readable message is exactly the one specified in the
        // task — clearly distinct from the generic start-failure message.
        #expect(message.contains("Refinement is still finishing up"))
        // Pause was attempted, resume was called as cleanup.
        #expect(await counter.pauseCount == 1)
        #expect(await counter.resumeCount == 1)
    }

    @Test("lock-probe failure does NOT call orchestrator.start")
    func lockProbeFailureSkipsStart() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Spy orchestrator that flips a flag if `start` is ever called.
        actor StartObserver { var startCalled = false
            func note() { startCalled = true } }
        let observer = StartObserver()
        final class WatchingOrchestrator: RecordingOrchestrating, @unchecked Sendable {
            let observer: StartObserver
            init(observer: StartObserver) { self.observer = observer }
            func start(readyTimeout: Duration) async throws {
                await observer.note()
            }
            func waitForEngineExit() async {}
            func isEngineRunning() async -> Bool { false }
            func stop() async {}
        }

        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in
                WatchingOrchestrator(observer: observer)
            },
            waitForWhisperLockFree: { throw ProbeTimeoutError() },
            preflight: .granted)

        await vm.startRecording()
        guard case .error = vm.status else {
            Issue.record("expected .error, got \(vm.status)")
            return
        }
        // The probe gate is enforced *before* `start` — the orchestrator
        // should never have been called.
        let called = await observer.startCalled
        #expect(called == false)
    }

    @Test("lock-probe success flows through to .recording (happy path)")
    func lockProbeSuccessReachesRecording() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let counter = CallCounter()
        let probeCalls = CallCounter()

        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            pauseRefinement: { await counter.incrementPause() },
            resumeRefinement: { await counter.incrementResume() },
            waitForWhisperLockFree: {
                // Default-happy probe: returns cleanly. Increment a
                // counter so we can assert the probe was actually
                // invoked (Layer B is wired in, not a no-op).
                await probeCalls.incrementPause()
            },
            preflight: .granted)

        await vm.startRecording()
        if case .recording = vm.status {} else {
            Issue.record("expected .recording, got \(vm.status)")
        }
        #expect(await probeCalls.pauseCount == 1)
        #expect(await counter.pauseCount == 1)
        // No resume yet — we're still recording.
        #expect(await counter.resumeCount == 0)
    }

    // MARK: - Permission preflight

    @Test("denied microphone surfaces .error and never calls orchestrator.start")
    func deniedMicrophoneBlocksStart() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()

        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            preflight: PermissionPreflight(
                microphone: { false },
                screenRecording: { true }))

        await vm.startRecording()
        guard case .error(let message) = vm.status else {
            Issue.record("expected .error, got \(vm.status)")
            return
        }
        #expect(message.contains("Microphone"))
        #expect(stub.startCalled == false)
    }

    @Test("denied screen recording with system audio on surfaces .error, start never called")
    func deniedScreenRecordingBlocksStart() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()

        let settings = try settings(outputRoot: root)
        settings.systemAudioEnabled = true
        let vm = RecordingViewModel(
            settings: settings,
            orchestratorFactory: { _, _ in stub },
            preflight: PermissionPreflight(
                microphone: { true },
                screenRecording: { false }))

        await vm.startRecording()
        guard case .error(let message) = vm.status else {
            Issue.record("expected .error, got \(vm.status)")
            return
        }
        #expect(message.contains("Screen Recording"))
        #expect(stub.startCalled == false)
    }

    @Test("denied screen recording is ignored when system audio is off")
    func deniedScreenRecordingIgnoredWithoutSystemAudio() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()

        let settings = try settings(outputRoot: root)
        settings.systemAudioEnabled = false
        let vm = RecordingViewModel(
            settings: settings,
            orchestratorFactory: { _, _ in stub },
            preflight: PermissionPreflight(
                microphone: { true },
                screenRecording: { false }))

        await vm.startRecording()
        if case .recording = vm.status {} else {
            Issue.record("expected .recording, got \(vm.status)")
        }
        await vm.stopRecording()
    }

    @Test("both grants flow through to .recording")
    func grantedPreflightReachesRecording() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let vm = makeVM(settings: try settings(outputRoot: root), orchestrator: stub)

        await vm.startRecording()
        if case .recording = vm.status {} else {
            Issue.record("expected .recording, got \(vm.status)")
        }
        #expect(stub.startCalled == true)
        await vm.stopRecording()
    }

    private actor PlanMailbox {
        private var plan: RecordPlan?
        func set(_ p: RecordPlan) { plan = p }
        func value() -> RecordPlan? { plan }
    }
}

extension PermissionPreflight {
    /// All-granted preflight for tests — never touches real TCC. Every VM
    /// construction in this target must pass an explicit preflight; the
    /// production default `.live` would hit the OS permission machinery.
    static var granted: PermissionPreflight {
        PermissionPreflight(microphone: { true }, screenRecording: { true })
    }
}

/// Captures (url, recordingId) pairs passed to `enqueueAutoRefine`.
actor EnqueueMailbox {
    var entries: [(url: URL, recordingId: String)] = []
    func record(url: URL, recordingId: String) { entries.append((url, recordingId)) }
}

/// Counts `pauseRefinement` / `resumeRefinement` invocations from tests.
/// Actor-based for safe cross-isolation reads.
actor CallCounter {
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    func incrementPause() { pauseCount += 1 }
    func incrementResume() { resumeCount += 1 }
}
