import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 2 — `RecordOrchestrator`, the capture↔engine subprocess dance behind
/// `pulsartrace record` (R47).
///
/// Real audio is not needed: the orchestrator is binary-agnostic, so stand-in
/// `/bin/sh` scripts emulate `pulsartrace-capture` (prints `ready`, then idles
/// until SIGTERM) and `pulsartrace-engine` (prints a summary line, exits). The
/// process lifecycle — launch, `ready` handshake, timeout, teardown — is what
/// is under test.
///
/// The idle scripts `exec sleep` so SIGTERM kills the process directly,
/// leaving no orphan holding the stdout pipe open.
@Suite("RecordOrchestrator (record, R47)")
struct RecordOrchestratorTests {

    private let sh = URL(fileURLWithPath: "/bin/sh")

    private func config(
        capture: String, engine: String
    ) -> RecordOrchestrator.Configuration {
        RecordOrchestrator.Configuration(
            captureBinary: sh, captureArguments: ["-c", capture],
            engineBinary: sh, engineArguments: ["-c", engine])
    }

    @Test("ready handshake then a clean engine run yields the engine summary")
    func happyPath() async throws {
        // Capture announces ready and idles; the engine prints its summary
        // line and exits on its own (as it does when the sockets reach EOF).
        let orchestrator = RecordOrchestrator(configuration: config(
            capture: "echo ready; exec sleep 10",
            engine: "echo 'live.md=/tmp/x lines=3'; exit 0"))

        try await orchestrator.start(readyTimeout: .seconds(5))
        await orchestrator.waitForEngineExit()
        let outcome = await orchestrator.stop()

        #expect(outcome.engineExitCode == 0)
        #expect(outcome.engineSummary == "live.md=/tmp/x lines=3")
    }

    @Test("a capture daemon that never becomes ready times out")
    func readyTimeout() async {
        let orchestrator = RecordOrchestrator(configuration: config(
            capture: "exec sleep 10", engine: "exit 0"))
        await #expect(throws: RecordOrchestrator.StartError.readyTimedOut) {
            try await orchestrator.start(readyTimeout: .milliseconds(400))
        }
    }

    @Test("capture exiting before ready surfaces its code and stderr")
    func captureExitsBeforeReady() async {
        let orchestrator = RecordOrchestrator(configuration: config(
            capture: "echo 'microphone permission not granted' >&2; exit 2",
            engine: "exit 0"))
        do {
            try await orchestrator.start(readyTimeout: .seconds(5))
            Issue.record("start() should have thrown")
        } catch let error as RecordOrchestrator.StartError {
            guard case .captureExitedBeforeReady(let code, let stderr) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(code == 2)
            #expect(stderr.contains("microphone permission"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("stop() SIGTERMs a still-running engine after the grace window")
    func stopForceTerminatesWedgedEngine() async throws {
        // The engine ignores the closed sockets and just sleeps; stop() must
        // still return, force-terminating it once the grace window elapses.
        let orchestrator = RecordOrchestrator(configuration: config(
            capture: "echo ready; exec sleep 10",
            engine: "exec sleep 10"))
        try await orchestrator.start(readyTimeout: .seconds(5))
        #expect(await orchestrator.isEngineRunning())

        let outcome = await orchestrator.stop(engineGrace: .milliseconds(300))
        #expect(outcome.engineExitCode != 0)   // killed by signal, not a clean exit
        #expect(await !orchestrator.isEngineRunning())
    }
}
