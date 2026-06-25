import Foundation
import Testing
@testable import PulsarTraceEngine

/// Cancellation and timeout semantics of the in-process `Diarizer` (PT-P5-D3).
///
/// Both are exercised through the test-only `operation:` seam, so they run
/// without CoreML models: the seam stands in for the FluidAudio engine call
/// while `Diarizer`'s `Task`-cancellation + watchdog machinery is the system
/// under test.
@Suite("Diarizer cancellation and timeout")
struct DiarizerCancelTests {

    /// A real (tiny) WAV so the existence guard passes.
    private func makeWAV(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("tiny.wav")
        try WAVWriter.write(
            samples: [Float](repeating: 0, count: AudioFormat.sampleRate / 10),
            to: url)
        return url
    }

    @Test func cancelThrowsCancelled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeWAV(in: dir)

        let diarizer = Diarizer(
            configuration: .init(timeout: .seconds(600)),
            operation: { _ in
                try await Task.sleep(for: .seconds(60))
                return DiarizationResultMapper.map(
                    segments: [], speakerDatabase: [:],
                    audioDuration: .zero, modelRevision: "")
            })
        let run = Task { try await diarizer.diarizeSystemStream(wavPath: wav) }
        try await Task.sleep(for: .milliseconds(200))   // let it get in flight
        await diarizer.cancel()

        await #expect(throws: Diarizer.DiarizeError.cancelled) {
            try await run.value
        }
    }

    @Test func timeoutThrowsTimedOut() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeWAV(in: dir)

        // 0.1 s of audio keeps the effective timeout at the 1 s floor.
        let diarizer = Diarizer(
            configuration: .init(timeout: .seconds(1)),
            operation: { _ in
                try await Task.sleep(for: .seconds(60))
                return DiarizationResultMapper.map(
                    segments: [], speakerDatabase: [:],
                    audioDuration: .zero, modelRevision: "")
            })
        await #expect(throws: Diarizer.DiarizeError.timedOut(seconds: 1)) {
            try await diarizer.diarizeSystemStream(wavPath: wav)
        }
    }

    @Test func missingWAVThrowsWavNotFound() async throws {
        let diarizer = Diarizer(configuration: .init())
        await #expect(throws: Diarizer.DiarizeError.self) {
            try await diarizer.diarizeSystemStream(
                wavPath: URL(fileURLWithPath: "/nonexistent/x.wav"))
        }
    }
}
