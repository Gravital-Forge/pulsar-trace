import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// Fixture-capture start/stop semantics (PT-P7-R2).
@MainActor
@Suite("RecordingViewModel fixture mode")
struct RecordingFixtureModeTests {

    /// Orchestrator stub: start succeeds; `waitForEngineExit` returns when
    /// `exitNow` fires (or immediately with `exitImmediately`).
    final class StubOrchestrator: RecordingOrchestrating, @unchecked Sendable {
        let exitImmediately: Bool
        private let exited: AsyncStream<Void>
        private let exit: AsyncStream<Void>.Continuation
        init(exitImmediately: Bool = false) {
            self.exitImmediately = exitImmediately
            (exited, exit) = AsyncStream.makeStream()
        }
        func exitNow() { exit.yield(); exit.finish() }
        func start(readyTimeout: Duration) async throws {}
        func waitForEngineExit() async {
            guard !exitImmediately else { return }
            for await _ in exited { break }
        }
        func isEngineRunning() async -> Bool { false }
        func stop() async {}
    }

    /// Reference-semantics mailbox so @Sendable closures can record into it —
    /// Swift 6 forbids mutating a captured local. `@unchecked Sendable` is
    /// sound here because each write happens before the awaited closure that
    /// performs it returns, and the test only reads `value` after observing the
    /// resulting state change — the `await` chain establishes happens-before.
    final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    private var fixtureOverrides: EnvironmentOverrides {
        EnvironmentOverrides(environment: [
            "PULSARTRACE_SYSTEM_FIXTURE": "/tmp/fx/system.wav",
            "PULSARTRACE_MIC_FIXTURE": "/tmp/fx/mic.wav",
            "PULSARTRACE_HOME": FileManager.default.temporaryDirectory
                .appendingPathComponent("pt-fxm-\(UUID().uuidString)").path,
        ])
    }

    private func settings() -> (MenuBarSettings, String) {
        let suite = "com.gravitalforge.PulsarTrace.fxm-\(UUID().uuidString)"
        return (MenuBarSettings(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    @Test("fixture start skips the TCC preflight and builds a fixture plan")
    func skipsPreflight() async {
        let (s, suite) = settings()
        let outRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fxm-out-\(UUID().uuidString)")
        s.outputFolderPath = outRoot.path
        let overrides = fixtureOverrides
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: outRoot)
            if let home = overrides.home {
                try? FileManager.default.removeItem(at: home)
            }
        }
        let planBox = Box<RecordPlan>()
        let vm = RecordingViewModel(
            settings: s,
            orchestratorFactory: { plan, _ in
                planBox.value = plan
                return StubOrchestrator()
            },
            // A denied preflight must NOT block a fixture start (PT-P7-R2).
            preflight: PermissionPreflight(
                microphone: { false }, screenRecording: { false }),
            overrides: overrides)
        await vm.startRecording()
        #expect(vm.status.canStopRecording)
        #expect(planBox.value?.captureArguments.isEmpty == true)
        #expect(planBox.value?.engineArguments.contains("fixture") == true)
    }

    @Test("engine self-exit at fixture EOF finalizes as a clean stop")
    func eofIsCleanStop() async throws {
        let (s, suite) = settings()
        let outRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fxm-out-\(UUID().uuidString)")
        s.outputFolderPath = outRoot.path
        let overrides = fixtureOverrides
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: outRoot)
            if let home = overrides.home {
                try? FileManager.default.removeItem(at: home)
            }
        }
        let refinedBox = Box<(URL, String)>()
        let stub = StubOrchestrator(exitImmediately: true)
        let vm = RecordingViewModel(
            settings: s,
            orchestratorFactory: { _, _ in stub },
            enqueueAutoRefine: { url, id in refinedBox.value = (url, id) },
            preflight: PermissionPreflight(
                microphone: { false }, screenRecording: { false }),
            overrides: overrides)
        await vm.startRecording()
        // The crash watch observes the (immediate) exit asynchronously.
        for _ in 0..<50 where vm.status != .idle {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(vm.status == .idle)          // never .crashed (PT-P7-R2)
        #expect(refinedBox.value != nil)
    }

    @Test("device sessions still crash on unexpected engine exit")
    func deviceStillCrashes() async throws {
        let (s, suite) = settings()
        let outRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fxm-out-\(UUID().uuidString)")
        s.outputFolderPath = outRoot.path
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: outRoot)
        }
        let stub = StubOrchestrator(exitImmediately: true)
        let vm = RecordingViewModel(
            settings: s,
            orchestratorFactory: { _, _ in stub },
            preflight: PermissionPreflight(
                microphone: { true }, screenRecording: { true }),
            overrides: EnvironmentOverrides(environment: [:]))
        await vm.startRecording()
        var crashed = false
        for _ in 0..<50 {
            if case .crashed = vm.status { crashed = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(crashed)
    }
}
