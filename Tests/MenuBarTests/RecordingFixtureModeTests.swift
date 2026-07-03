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
    /// Swift 6 forbids mutating a captured local; this is the
    /// RecordingViewModelTests idiom.
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

    private func settings() -> MenuBarSettings {
        let suite = "com.gravitalforge.PulsarTrace.fxm-\(UUID().uuidString)"
        return MenuBarSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("fixture start skips the TCC preflight and builds a fixture plan")
    func skipsPreflight() async {
        let s = settings()
        s.outputFolderPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fxm-out-\(UUID().uuidString)").path
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
            overrides: fixtureOverrides)
        await vm.startRecording()
        #expect(vm.status.canStopRecording)
        #expect(planBox.value?.captureArguments.isEmpty == true)
        #expect(planBox.value?.engineArguments.contains("fixture") == true)
    }

    @Test("engine self-exit at fixture EOF finalizes as a clean stop")
    func eofIsCleanStop() async throws {
        let s = settings()
        s.outputFolderPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fxm-out-\(UUID().uuidString)").path
        let refinedBox = Box<(URL, String)>()
        let stub = StubOrchestrator(exitImmediately: true)
        let vm = RecordingViewModel(
            settings: s,
            orchestratorFactory: { _, _ in stub },
            enqueueAutoRefine: { url, id in refinedBox.value = (url, id) },
            preflight: PermissionPreflight(
                microphone: { false }, screenRecording: { false }),
            overrides: fixtureOverrides)
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
        let s = settings()
        s.outputFolderPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-fxm-out-\(UUID().uuidString)").path
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
