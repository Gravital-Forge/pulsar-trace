import Testing
import Foundation
import PulsarTraceEngine
@testable import PulsarTraceMenuBar

/// The fixture-mode session driver (PT-P7-R2).
@Suite("EngineOnlyOrchestrator", .serialized)
struct EngineOnlyOrchestratorTests {

    /// Write an executable stand-in script and return its URL.
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-eoo-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(
            to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("engine exit is observed; liveness flips")
    func exitObserved() async throws {
        let bin = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: bin) }
        let o = EngineOnlyOrchestrator(engineBinary: bin, engineArguments: [])
        try await o.start(readyTimeout: .seconds(5))
        await o.waitForEngineExit()
        #expect(await o.isEngineRunning() == false)
    }

    @Test("stop terminates a long-running engine")
    func stopTerminates() async throws {
        let bin = try script("sleep 60")
        defer { try? FileManager.default.removeItem(at: bin) }
        let o = EngineOnlyOrchestrator(engineBinary: bin, engineArguments: [])
        try await o.start(readyTimeout: .seconds(5))
        #expect(await o.isEngineRunning() == true)
        await o.stop()
        #expect(await o.isEngineRunning() == false)
    }

    @Test("a missing binary throws engineLaunchFailed")
    func launchFailure() async {
        let o = EngineOnlyOrchestrator(
            engineBinary: URL(fileURLWithPath: "/nonexistent/pt-engine"),
            engineArguments: [])
        await #expect(throws: RecordOrchestrator.StartError.self) {
            try await o.start(readyTimeout: .seconds(5))
        }
    }

    @Test("stop after natural exit is a safe no-op")
    func stopAfterExit() async throws {
        let bin = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: bin) }
        let o = EngineOnlyOrchestrator(engineBinary: bin, engineArguments: [])
        try await o.start(readyTimeout: .seconds(5))
        await o.waitForEngineExit()
        await o.stop() // must not hang or crash
        #expect(await o.isEngineRunning() == false)
    }
}
