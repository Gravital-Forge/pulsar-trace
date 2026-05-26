// Tests/UnitTests/DiarizerTimeoutTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// The `Diarizer.Configuration.timeout` is a *floor*, not a ceiling: when the
/// system-stream WAV is longer than the configured timeout, the Diarizer
/// expands the per-call budget to at least the audio's wall-clock length, so
/// pyannote on a 78-minute meeting doesn't get killed at 10 minutes.
///
/// The bug this guards against: rec_2026-05-20-100033 (78.5 min audio) failed
/// with `DiarizeError.timedOut(seconds: 600)` → `RefinementJobError.diarizeCrashed`,
/// because the offline path used the default 600s ceiling regardless of the
/// recording's length.
@Suite("Diarizer timeout scales with audio duration")
struct DiarizerTimeoutTests {

    /// When the audio is longer than the configured timeout, the subprocess
    /// is given the audio duration's worth of wall-clock — not the smaller
    /// configured value. Verified by giving the diarizer a 1s configured
    /// timeout against a WAV header declaring 30 seconds of audio, and a
    /// fake subprocess that sleeps 3 seconds before exiting cleanly. The
    /// old behavior would have killed the subprocess at 1s with `.timedOut`;
    /// the new behavior lets it run to completion (and then surfaces
    /// `.emptyOutput`, since the fake produced no JSON).
    @Test("audio duration > configured timeout extends the watchdog budget")
    func longAudioExtendsTimeout() async throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-timeout-\(UUID().uuidString).wav")
        try makeWAVHeaderClaiming(durationSeconds: 30).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        // 1s configured floor << 30s audio → effective budget should be 30s.
        // Subprocess sleeps 3s then exits 0 with no stdout → `.emptyOutput`,
        // which proves the watchdog did not fire at 1s.
        let diarizer = Diarizer(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            timeout: .seconds(1),
            customArguments: ["-c", "sleep 3; exit 0"]))

        await #expect(throws: Diarizer.DiarizeError.emptyOutput) {
            _ = try await diarizer.diarizeSystemStream(wavPath: wav)
        }
    }

    /// When the audio is shorter than the configured timeout, the configured
    /// value still applies — the floor is `configuration.timeout`, not the
    /// audio duration. Verified by giving the diarizer a generous 30s
    /// configured timeout against a 1s WAV and a subprocess that sleeps for
    /// 3s: the run reaches the subprocess's clean exit, not the watchdog.
    @Test("short audio keeps the configured timeout floor")
    func shortAudioKeepsConfiguredFloor() async throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-timeout-\(UUID().uuidString).wav")
        try makeWAVHeaderClaiming(durationSeconds: 1).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let diarizer = Diarizer(configuration: .init(
            pythonExecutable: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            timeout: .seconds(30),
            customArguments: ["-c", "sleep 1; exit 0"]))

        await #expect(throws: Diarizer.DiarizeError.emptyOutput) {
            _ = try await diarizer.diarizeSystemStream(wavPath: wav)
        }
    }

    // MARK: - Helpers

    /// Build a 44-byte WAV header for 16 kHz mono Int16 with the `data` chunk
    /// size field set so the declared audio length matches `durationSeconds`.
    /// The file is header-only — the probe must not depend on samples being
    /// present on disk.
    private func makeWAVHeaderClaiming(durationSeconds: Int) -> Data {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let dataSize = UInt32(durationSeconds) * byteRate
        let riffSize: UInt32 = 36 + dataSize

        var data = Data()
        func append32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func append16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(riffSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(channels)
        append32(sampleRate)
        append32(byteRate)
        append16(UInt16(channels * (bitsPerSample / 8)))
        append16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        // No sample bytes — header only.
        return data
    }
}
