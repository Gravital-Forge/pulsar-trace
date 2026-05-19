// Tests/UnitTests/ResumableRefinerTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("ResumableRefiner")
struct ResumableRefinerTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-resumable-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a fresh run leaves a completed-stage checkpoint in the folder")
    func freshRunCheckpoint() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "stub")],
                    language: "en")
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(1))]
            },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(1),
                    speakers: ["SPEAKER_00"],
                    spans: [SpeakerSpan(
                        speaker: "SPEAKER_00",
                        start: .seconds(0),
                        end: .seconds(1))],
                    exclusiveSpans: [SpeakerSpan(
                        speaker: "SPEAKER_00",
                        start: .seconds(0),
                        end: .seconds(1))],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_x", recordingId: "rec_x", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        let progressURL = folder.appendingPathComponent("refine-progress.json")
        let data = try Data(contentsOf: progressURL)
        let progress = try RefinementProgress.decode(data)
        #expect(progress.stage == .writingMetadata)

        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("final.md").path))
        #expect(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("metadata.json").path))
    }
}

enum FixtureRecording {
    /// Write a minimal recording folder with a 2-second silent `audio-system.wav`.
    /// Two seconds (32 000 samples at 16 kHz) gives `RecordingFolder.resolve`
    /// a valid WAV with a non-empty data chunk.
    static func minimal(at folder: URL) throws {
        let wav = folder.appendingPathComponent("audio-system.wav")
        try WAVWriter.write(samples: [Float](repeating: 0, count: 32_000), to: wav)
    }
}
