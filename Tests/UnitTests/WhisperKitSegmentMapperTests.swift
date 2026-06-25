import Testing
@testable import PulsarTraceEngine

@Suite("WhisperKitSegmentMapper")
struct WhisperKitSegmentMapperTests {

    private func seg(
        _ text: String, _ start: Float, _ end: Float,
        noSpeech: Float = 0.05, avgLogprob: Float = -0.2
    ) -> WhisperKitSegmentMapper.InputSegment {
        .init(text: text, start: start, end: end,
              noSpeechProb: noSpeech, avgLogprob: avgLogprob)
    }

    @Test func shiftsOntoRecordingTimeline() {
        let out = WhisperKitSegmentMapper.segments(
            from: [seg(" Hello there.", 1.0, 2.5)],
            shiftedBy: .seconds(100),
            dropHallucinations: true)
        #expect(out == [TranscriptSegment(
            start: .milliseconds(101_000),
            end: .milliseconds(102_500),
            text: "Hello there.")])
    }

    @Test func dropsBlankAndEmptySegments() {
        let out = WhisperKitSegmentMapper.segments(
            from: [seg("[BLANK_AUDIO]", 0, 1), seg("   ", 1, 2), seg("Real words", 2, 3)],
            shiftedBy: .zero,
            dropHallucinations: true)
        #expect(out.map(\.text) == ["Real words"])
    }

    @Test func hallucinationDoubleGateMirrorsD31() {
        // Stock phrase + silence signal → dropped.
        let hallucinated = seg("Thank you.", 0, 1, noSpeech: 0.45, avgLogprob: -0.3)
        // Same phrase, confident decode → kept (a real person said it).
        let genuine = seg("Thank you.", 1, 2, noSpeech: 0.05, avgLogprob: -0.2)
        // Non-stock text, terrible confidence → kept (gate needs BOTH).
        let lowConfidence = seg("quarterly revenue numbers", 2, 3,
                                noSpeech: 0.5, avgLogprob: -1.5)
        let out = WhisperKitSegmentMapper.segments(
            from: [hallucinated, genuine, lowConfidence],
            shiftedBy: .zero,
            dropHallucinations: true)
        #expect(out.map(\.text) == ["Thank you.", "quarterly revenue numbers"])
    }

    @Test func gateOffKeepsEverythingNonBlank() {
        let out = WhisperKitSegmentMapper.segments(
            from: [seg("Thank you.", 0, 1, noSpeech: 0.45, avgLogprob: -0.9)],
            shiftedBy: .zero,
            dropHallucinations: false)
        #expect(out.count == 1)
    }
}
