// Tests/UnitTests/ResumableRefinerTests.swift
import Foundation
import os
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

    /// A pre-written progress file with two of three regions completed makes the
    /// refiner skip those two and decode only the third.
    @Test("resume from checkpoint skips already-completed regions")
    func resumeFromCheckpoint() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FixtureRecording.minimal(at: folder)

        // Hand-write a progress file claiming regions 0+1 already decoded.
        var seed = RefinementProgress.empty(jobId: "job_r", recordingId: "rec_r")
        seed.stage = .transcribingSystem
        seed.systemRegions = [
            .init(startMillis: 0,    endMillis: 1000),
            .init(startMillis: 1000, endMillis: 2000),
            .init(startMillis: 2000, endMillis: 3000),
        ]
        seed.completedSystemRegionIndices = [0, 1]
        seed.systemSegments = [
            .init(startMillis: 0,    endMillis: 1000, text: "preexisting 0", regionIndex: 0),
            .init(startMillis: 1000, endMillis: 2000, text: "preexisting 1", regionIndex: 1),
        ]
        seed.language = "en"
        seed.lastCheckpointAt = Date()
        try seed.encoded().write(
            to: folder.appendingPathComponent("refine-progress.json"))

        // Track which region indices the transcribe stub is asked to decode.
        // OSAllocatedUnfairLock is Sendable so it is safe to capture in @Sendable closures.
        let callLog = OSAllocatedUnfairLock(initialState: [Int]())

        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                // Identify the region by its start time (whole seconds → index).
                let i = Int(region.start.seconds)
                callLog.withLock { $0.append(i) }
                return TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: "fresh \(i)")],
                    language: "en")
            },
            detectRegions: { _ in
                // Should not be called — regions are already in the checkpoint.
                Issue.record("detectRegions was called on resume")
                return []
            },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    modelVersion: "stub",
                    audioDuration: .seconds(3),
                    speakers: [],
                    spans: [],
                    exclusiveSpans: [],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        // RefinementJob id+recordingId must match the seed so that
        // loadOrInitProgress picks up the checkpoint (not a fresh empty one).
        let job = RefinementJob(
            id: "job_r", recordingId: "rec_r", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        let indices = callLog.withLock { $0 }
        #expect(indices == [2])    // only region 2 decoded; 0+1 skipped by checkpoint
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
