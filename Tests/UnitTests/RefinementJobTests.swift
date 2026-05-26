// Tests/UnitTests/RefinementJobTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("RefinementJob")
struct RefinementJobTests {

    @Test("a queued job round-trips through JSON")
    func roundTripQueued() throws {
        let job = RefinementJob(
            id: "job_01HZ",
            recordingId: "rec_2026-05-19-1430",
            folderURL: URL(fileURLWithPath: "/tmp/rec"),
            modelName: "base",
            modelSHA256: "deadbeef",
            trigger: .autoPostRecording,
            enqueuedAt: Date(timeIntervalSince1970: 1_716_120_000),
            state: .queued)

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(RefinementJob.self, from: data)
        #expect(decoded == job)
    }

    @Test("state .running carries a stage and a progress fraction")
    func runningCarriesProgress() {
        let state: RefinementJobState = .running(
            stage: .transcribingSystem,
            stepsCompleted: 3,
            stepsTotal: 6,
            regionIndex: 4,
            regionsTotal: 12)
        #expect(state.progressFraction != nil)
        #expect(state.progressFraction! > 0.0 && state.progressFraction! < 1.0)
    }

    // MARK: - displayName

    @Test("Stage.displayName returns human-readable labels, not rawValues")
    func stageDisplayNames() {
        #expect(RefinementJobState.Stage.resolvingInput.displayName == "Loading audio")
        #expect(RefinementJobState.Stage.transcribingSystem.displayName == "Transcribing system")
        #expect(RefinementJobState.Stage.diarizing.displayName == "Diarizing")
        #expect(RefinementJobState.Stage.transcribingMic.displayName == "Transcribing mic")
        #expect(RefinementJobState.Stage.merging.displayName == "Merging")
        #expect(RefinementJobState.Stage.writingFinal.displayName == "Writing transcript")
        #expect(RefinementJobState.Stage.writingMetadata.displayName == "Writing metadata")
    }

    @Test("PauseReason.displayName returns human-readable labels, not rawValues")
    func pauseReasonDisplayNames() {
        #expect(RefinementJobState.PauseReason.userRequested.displayName == "User paused")
        #expect(RefinementJobState.PauseReason.recordingInProgress.displayName == "Recording in progress")
    }
}
