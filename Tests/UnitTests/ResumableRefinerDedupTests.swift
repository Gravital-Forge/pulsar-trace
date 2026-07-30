// Tests/UnitTests/ResumableRefinerDedupTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("ResumableRefiner drops mic echoes in the merge (PT-R145)")
struct ResumableRefinerDedupTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pt-rr-dedup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write both a system and a mic WAV so `RecordingFolder.resolve` sees a
    /// mic stream (`folder.micStream != nil`) and the refiner transcribes it —
    /// `FixtureRecording.minimal` writes only `audio-system.wav`, which would
    /// leave the mic path unexercised.
    private func writePairedFixture(at folder: URL) throws {
        let silence = [Float](repeating: 0, count: 32_000)   // 2 s @ 16 kHz
        try WAVWriter.write(
            samples: silence,
            to: folder.appendingPathComponent(RecordingFolder.FileName.audioSystem))
        try WAVWriter.write(
            samples: silence,
            to: folder.appendingPathComponent(RecordingFolder.FileName.audioMic))
    }

    @Test("a scripted mic duplicate of a system segment never reaches final.md")
    func micEchoAbsentFromFinal() async throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writePairedFixture(at: folder)

        let echoText = "we will ship the beta on thursday"
        let refiner = ResumableRefiner(
            transcribe: { _, region, _ in
                // The same text comes back for both streams' single region:
                // system speaks it; the mic hears it as room bleed-through.
                TranscriptionResult(
                    segments: [TranscriptSegment(
                        start: region.start, end: region.end, text: echoText)],
                    language: "en")
            },
            detectRegions: { _ in
                [SpeechRegion(start: .seconds(0), end: .seconds(2))]
            },
            diarize: { _ in
                DiarizationResult(
                    model: "stub",
                    audioDuration: .seconds(2),
                    speakers: ["SPEAKER_00"],
                    spans: [SpeakerSpan(
                        speaker: "SPEAKER_00",
                        start: .seconds(0), end: .seconds(2))],
                    embeddings: [])
            },
            pauseGate: PauseGate(initiallyOpen: true),
            events: nil)

        let job = RefinementJob(
            id: "job_dedup", recordingId: "rec_dedup", folderURL: folder,
            modelName: "stub", modelSHA256: "stub",
            trigger: .manual, enqueuedAt: Date(), state: .queued)
        try await refiner.run(job: job)

        let final = try String(
            contentsOf: folder.appendingPathComponent("final.md"), encoding: .utf8)
        // The system line survives; no "You" duplicate of it exists.
        #expect(final.contains(echoText))
        #expect(!final.contains("] You:**"))
    }
}
