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
}
