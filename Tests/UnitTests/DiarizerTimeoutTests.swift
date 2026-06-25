// Tests/UnitTests/DiarizerTimeoutTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

/// The `Diarizer.Configuration.timeout` is a *floor*, not a ceiling: when the
/// system-stream WAV is longer than the configured timeout, the Diarizer
/// expands the per-call budget to at least the audio's wall-clock length, so
/// diarization of a 78-minute meeting doesn't get killed at 10 minutes.
///
/// The bug this guards against: rec_2026-05-20-100033 (78.5 min audio) failed
/// with `DiarizeError.timedOut(seconds: 600)` → `RefinementJobError.diarizeCrashed`,
/// because the offline path used the default 600s ceiling regardless of the
/// recording's length.
///
/// Exercised through the test-only `operation:` seam (PT-P5-D3, in-process): the
/// seam stands in for the FluidAudio engine call while the watchdog's
/// floor-expansion is the system under test. A header-only WAV declares the
/// audio's length so the probe can read it without samples on disk.
@Suite("Diarizer timeout scales with audio duration")
struct DiarizerTimeoutTests {

    /// When the audio is longer than the configured timeout, the watchdog is
    /// given the audio duration's worth of wall-clock — not the smaller
    /// configured value. Verified with a 1 s configured floor against a WAV
    /// header declaring 3 s of audio, and an operation that takes ~1.4 s: the
    /// old 1 s ceiling would have fired `.timedOut`; the expanded 3 s budget
    /// lets it run to completion.
    @Test("audio duration > configured timeout extends the watchdog budget")
    func longAudioExtendsTimeout() async throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-timeout-\(UUID().uuidString).wav")
        try makeWAVHeaderClaiming(durationSeconds: 3).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let diarizer = Diarizer(
            configuration: .init(timeout: .seconds(1)),
            operation: { _ in
                try await Task.sleep(for: .milliseconds(1400))
                return DiarizationResultMapper.map(
                    segments: [], speakerDatabase: [:],
                    audioDuration: .seconds(3), modelRevision: "rev")
            })

        // Must NOT throw `.timedOut` — the budget expanded to 3 s.
        let result = try await diarizer.diarizeSystemStream(wavPath: wav)
        #expect(result.modelRevision == "rev")
    }

    /// When the audio is shorter than the configured timeout, the configured
    /// value still applies — the floor is `configuration.timeout`, not the
    /// audio duration. Verified with a generous 3 s configured floor against a
    /// 1 s WAV and an operation that takes ~1.4 s: it reaches completion well
    /// inside the 3 s floor.
    @Test("short audio keeps the configured timeout floor")
    func shortAudioKeepsConfiguredFloor() async throws {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-timeout-\(UUID().uuidString).wav")
        try makeWAVHeaderClaiming(durationSeconds: 1).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let diarizer = Diarizer(
            configuration: .init(timeout: .seconds(3)),
            operation: { _ in
                try await Task.sleep(for: .milliseconds(1400))
                return DiarizationResultMapper.map(
                    segments: [], speakerDatabase: [:],
                    audioDuration: .seconds(1), modelRevision: "rev")
            })

        let result = try await diarizer.diarizeSystemStream(wavPath: wav)
        #expect(result.modelRevision == "rev")
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
