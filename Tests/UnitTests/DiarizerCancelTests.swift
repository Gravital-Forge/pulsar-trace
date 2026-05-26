// Tests/UnitTests/DiarizerCancelTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("Diarizer cancel")
struct DiarizerCancelTests {

    /// `cancel()` is a no-op when no subprocess is running.
    @Test("cancel on an idle diarizer does not throw")
    func idleCancel() async {
        let diarizer = Diarizer(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/false"),
            workingDirectory: URL(fileURLWithPath: "/tmp")))
        await diarizer.cancel()
    }

    /// When `cancel()` is called against an inflight subprocess, the
    /// in-flight `diarizeSystemStream` call throws `.cancelled` (not the
    /// generic `.nonZeroExit`) so the refiner can distinguish a pause from
    /// a real failure.
    ///
    /// Driven via `/bin/sh` with `customArguments` overriding the module-based
    /// argv to `["-c", "sleep 30"]`, so the test does not need a real Python venv.
    @Test("cancel against an inflight diarize throws .cancelled")
    func cancelInflight() async throws {
        // Write a temp WAV the resolver accepts as input. (Empty file is
        // fine — the subprocess is fake.)
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-cancel-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        // customArguments overrides the normal `-m pulsartrace_ai.diarize <wav>`
        // argv so that /bin/sh runs `sleep 30` — a long-lived stand-in for the
        // real Python subprocess.
        let diarizer = Diarizer(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            customArguments: ["-c", "sleep 30"]))

        // Launch the diarize and cancel after a beat.
        let task = Task {
            try await diarizer.diarizeSystemStream(wavPath: wav)
        }
        try await Task.sleep(for: .milliseconds(100))
        await diarizer.cancel()

        await #expect(throws: Diarizer.DiarizeError.self) {
            _ = try await task.value
        }
        // Specifically the .cancelled case, not .nonZeroExit:
        do {
            _ = try await task.value
        } catch let e as Diarizer.DiarizeError {
            if case .cancelled = e {} else { Issue.record("wrong case: \(e)") }
        }
    }
}
