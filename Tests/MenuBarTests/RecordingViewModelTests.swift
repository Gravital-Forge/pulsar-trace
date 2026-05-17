import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// Epic 8 — `RecordingViewModel`'s status machine (R40, R45), exercised through
/// the injected orchestration seam so no real capture/engine processes spawn.
@Suite("RecordingViewModel (Epic 8)")
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

        init(startError: Error? = nil) {
            self.startError = startError
        }

        func start(readyTimeout: Duration) async throws {
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
        settings.outputFolderBookmark = try MenuBarSettings.makeBookmark(
            for: outputRoot)
        return settings
    }

    /// Build a VM around a given stub orchestrator and a no-op refiner.
    private func makeVM(
        settings: MenuBarSettings,
        orchestrator: StubOrchestrator
    ) -> RecordingViewModel {
        RecordingViewModel(
            settings: settings,
            orchestratorFactory: { _, _ in orchestrator },
            reRefiner: { _ in })
    }

    // MARK: - Tests

    @Test("happy path: idle → recording → refining → idle, refine targets the recorded folder")
    func happyPathTransitions() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()
        let refined = RefineMailbox()
        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            reRefiner: { url in await refined.record(url) })

        #expect(vm.status == .idle)
        await vm.startRecording()

        guard case .recording = vm.status else {
            Issue.record("expected .recording, got \(vm.status)")
            return
        }

        await vm.stopRecording()
        #expect(vm.status == .idle)
        #expect(stub.stopped)

        // The post-recording refine must receive the actual recording folder.
        // A freshly-recorded folder has no `metadata.json`, so it cannot be
        // re-discovered by scanning the output root — the VM must carry the
        // folder it created through to the refine pass (regression guard).
        #expect(await refined.count() == 1)
        let refinedURL = try #require(await refined.first())
        #expect(refinedURL.deletingLastPathComponent().standardizedFileURL
            == root.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: refinedURL.path))
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

    @Test("starting with no output folder surfaces .error")
    func noOutputFolderError() async {
        let defaults = UserDefaults(suiteName: "pt-rvm-noout-\(UUID().uuidString)")!
        let settings = MenuBarSettings(defaults: defaults)   // no output folder
        let vm = RecordingViewModel(
            settings: settings,
            orchestratorFactory: { _, _ in StubOrchestrator() },
            reRefiner: { _ in })

        await vm.startRecording()
        guard case .error = vm.status else {
            Issue.record("expected .error")
            return
        }
    }

    @Test("recoverFromCrash refines the partial folder and returns to idle")
    func recoverFromCrashRefines() async throws {
        let root = MenuBarFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubOrchestrator()

        let refined = RefineMailbox()
        let vm = RecordingViewModel(
            settings: try settings(outputRoot: root),
            orchestratorFactory: { _, _ in stub },
            reRefiner: { url in await refined.record(url) })

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
        #expect(await refined.count() == 1)
    }

    private actor RefineMailbox {
        private var urls: [URL] = []
        func record(_ u: URL) { urls.append(u) }
        func count() -> Int { urls.count }
        func first() -> URL? { urls.first }
    }
}
