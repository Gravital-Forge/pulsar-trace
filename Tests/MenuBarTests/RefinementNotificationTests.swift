// Tests/MenuBarTests/RefinementNotificationTests.swift
import Foundation
import Testing
@testable import PulsarTraceEngine
@testable import PulsarTraceMenuBar

@Suite("RefinementNotification")
struct RefinementNotificationTests {

    /// A terminal job in the given state — mirrors the construction idiom in
    /// `RefinementJobQueueViewModelTests` (stub model fields, /tmp folder).
    private func job(state: RefinementJobState) -> RefinementJob {
        RefinementJob(
            id: "job_test",
            recordingId: "rec_test",
            folderURL: URL(fileURLWithPath: "/tmp/rec_test"),
            modelName: "stub",
            modelSHA256: "stub",
            trigger: .autoPostRecording,
            enqueuedAt: Date(timeIntervalSince1970: 1_750_000_000),
            state: state)
    }

    @Test("completed job produces 'Transcript ready' with speakers and minutes")
    func completedContent() throws {
        let notification = RefinementNotification.from(
            job: job(state: .completed(durationSeconds: 2520, speakerCount: 3)))
        let unwrapped = try #require(notification)
        #expect(unwrapped.title == "Transcript ready")
        #expect(unwrapped.body.contains("3 speakers"))
        #expect(unwrapped.body.contains("42 min"))
        #expect(unwrapped.folderURL == URL(fileURLWithPath: "/tmp/rec_test"))
    }

    @Test("single speaker is rendered singular")
    func singularSpeaker() throws {
        let notification = RefinementNotification.from(
            job: job(state: .completed(durationSeconds: 60, speakerCount: 1)))
        let unwrapped = try #require(notification)
        #expect(unwrapped.body.contains("1 speaker,"),
                "speakerCount == 1 must render as '1 speaker', not '1 speakers'")
    }

    @Test("failed job produces 'Refinement failed' without raw error classes")
    func failedContent() throws {
        let notification = RefinementNotification.from(
            job: job(state: .failed(errorClass: "model_load_failed",
                                    retryAvailable: true)))
        let unwrapped = try #require(notification)
        #expect(unwrapped.title == "Refinement failed")
        #expect(!unwrapped.body.contains("model_load_failed"),
                "raw error classes must never be shown to the user")
    }

    @Test("cancelled job produces no notification")
    func cancelledIsNil() {
        #expect(RefinementNotification.from(job: job(state: .cancelled)) == nil)
    }

    @Test("non-terminal states produce no notification")
    func nonTerminalIsNil() {
        #expect(RefinementNotification.from(job: job(state: .queued)) == nil)
        #expect(RefinementNotification.from(
            job: job(state: .running(stage: .merging, stepsCompleted: 1,
                                     stepsTotal: 7, regionIndex: nil,
                                     regionsTotal: nil))) == nil)
    }
}
