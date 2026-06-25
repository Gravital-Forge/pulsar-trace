import Testing
import Foundation
@testable import PulsarTraceEngine

/// Layer 2 — `RecordOrchestrator`, the capture↔engine subprocess dance behind
/// `pulsartrace record` (PT-R47).
///
/// Real audio is not needed: the orchestrator is binary-agnostic, so stand-in
/// `/bin/sh` scripts emulate `pulsartrace-capture` (prints `ready`, then idles
/// until SIGTERM) and `pulsartrace-engine` (prints a summary line, exits). The
/// process lifecycle — launch, `ready` handshake, timeout, teardown — is what
/// is under test.
///
/// The idle scripts `exec sleep` so SIGTERM kills the process directly,
/// leaving no orphan holding the stdout pipe open.
@Suite("RecordOrchestrator (record, PT-R47)")
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

    // MARK: - engineEnvironment merge behavior
    //
    // The orchestrator's `engineEnvironment` field (the generic
    // subprocess-environment seam; no production caller sets it today) must
    // merge onto the parent process's environment (caller-wins) before being
    // assigned to the engine subprocess. Replacing rather than merging would
    // strip HOME, PATH, USER, etc. and break anything downstream that depends
    // on them. These tests assert the observable contract by spawning a
    // stand-in engine script that echoes the env it actually receives.

    /// Builds a config whose capture is a vanilla ready+idle script and whose
    /// engine is the supplied shell snippet (typically an `echo` reading env
    /// vars), then exits 0.
    private func engineEnvConfig(
        engine: String, engineEnvironment: [String: String]?
    ) -> RecordOrchestrator.Configuration {
        RecordOrchestrator.Configuration(
            captureBinary: sh,
            captureArguments: ["-c", "echo ready; exec sleep 10"],
            engineBinary: sh,
            engineArguments: ["-c", engine],
            engineEnvironment: engineEnvironment)
    }

    @Test("engineEnvironment nil leaves the engine inheriting parent env (HOME present)")
    func engineEnvironmentNilInheritsParent() async throws {
        // With no caller-supplied env, the orchestrator must leave
        // `engine.environment = nil` so the subprocess inherits the parent's
        // full env. HOME is virtually guaranteed to exist in the test host.
        let orchestrator = RecordOrchestrator(configuration: engineEnvConfig(
            engine: #"echo "HOME=$HOME"; exit 0"#,
            engineEnvironment: nil))

        try await orchestrator.start(readyTimeout: .seconds(5))
        await orchestrator.waitForEngineExit()
        let outcome = await orchestrator.stop()

        #expect(outcome.engineExitCode == 0)
        #expect(outcome.engineSummary.hasPrefix("HOME="))
        let value = String(outcome.engineSummary.dropFirst("HOME=".count))
        #expect(!value.isEmpty)
    }

    @Test("engineEnvironment non-nil makes the caller key visible to the engine")
    func engineEnvironmentPopulatesCallerKey() async throws {
        let orchestrator = RecordOrchestrator(configuration: engineEnvConfig(
            engine: #"echo "KEY=$PULSARTRACE_TEST_KEY"; exit 0"#,
            engineEnvironment: ["PULSARTRACE_TEST_KEY": "test-value-42"]))

        try await orchestrator.start(readyTimeout: .seconds(5))
        await orchestrator.waitForEngineExit()
        let outcome = await orchestrator.stop()

        #expect(outcome.engineExitCode == 0)
        #expect(outcome.engineSummary == "KEY=test-value-42")
    }

    @Test("engineEnvironment non-nil still preserves parent env (merge, not replace)")
    func engineEnvironmentPreservesParentEnv() async throws {
        // The bug we are guarding against: assigning `engine.environment` to
        // just the caller dict would drop HOME/PATH/USER. The script echoes
        // both the new key and HOME on a single delimited line so the assert
        // can verify both in one summary read.
        let orchestrator = RecordOrchestrator(configuration: engineEnvConfig(
            engine: #"echo "KEY=$PULSARTRACE_TEST_KEY|HOME=$HOME"; exit 0"#,
            engineEnvironment: ["PULSARTRACE_TEST_KEY": "x"]))

        try await orchestrator.start(readyTimeout: .seconds(5))
        await orchestrator.waitForEngineExit()
        let outcome = await orchestrator.stop()

        #expect(outcome.engineExitCode == 0)
        let parts = outcome.engineSummary.split(separator: "|", maxSplits: 1)
        #expect(parts.count == 2)
        guard parts.count == 2 else { return }
        #expect(parts[0] == "KEY=x")
        #expect(parts[1].hasPrefix("HOME="))
        let homeValue = parts[1].dropFirst("HOME=".count)
        #expect(!homeValue.isEmpty)
    }

    @Test("engineEnvironment caller value overrides the parent's value on duplicate keys")
    func engineEnvironmentCallerWinsOnDuplicateKeys() async throws {
        // Seed a process-level env var first so the parent env carries it,
        // then pass a different value for the same key in engineEnvironment.
        // The caller's value must win. Unset on the way out to keep this test
        // hermetic w.r.t. anything else in the suite.
        let key = "PULSARTRACE_TEST_OVERRIDE"
        setenv(key, "parent-value", 1)
        defer { unsetenv(key) }

        let orchestrator = RecordOrchestrator(configuration: engineEnvConfig(
            engine: #"echo "OVERRIDE=$PULSARTRACE_TEST_OVERRIDE"; exit 0"#,
            engineEnvironment: [key: "caller-value"]))

        try await orchestrator.start(readyTimeout: .seconds(5))
        await orchestrator.waitForEngineExit()
        let outcome = await orchestrator.stop()

        #expect(outcome.engineExitCode == 0)
        #expect(outcome.engineSummary == "OVERRIDE=caller-value")
    }
}
