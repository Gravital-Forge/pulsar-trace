import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("Owner profile learner — cluster selection (PT-P8-R3)")
struct OwnerProfileLearnerTests {

    private func seg(_ s: Double, _ e: Double) -> TranscriptSegment {
        TranscriptSegment(start: .seconds(s), end: .seconds(e), text: "words")
    }

    private func vec(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256); v[axis] = 1; return v
    }

    private func diarization(
        spans: [(String, Double, Double)], embeddings: [String: [Float]]
    ) -> DiarizationResult {
        DiarizationResult(
            model: "stub", modelRevision: "rev-stub",
            audioDuration: .seconds(60),
            speakers: Array(embeddings.keys).sorted(),
            spans: spans.map {
                SpeakerSpan(speaker: $0.0, start: .seconds($0.1), end: .seconds($0.2))
            },
            embeddings: embeddings.map {
                SpeakerEmbedding(speaker: $0.key, vector: $0.value)
            })
    }

    @Test("the cluster dominant over surviving mic speech wins")
    func dominantClusterWins() {
        // SPEAKER_00 covers 0–40 s (the user); SPEAKER_01 covers 40–45 s
        // (bleed-through that dedup mostly removed from the segments).
        let result = OwnerProfileLearner.ownerEmbedding(
            micDiarization: diarization(
                spans: [("SPEAKER_00", 0, 40), ("SPEAKER_01", 40, 45)],
                embeddings: ["SPEAKER_00": vec(0), "SPEAKER_01": vec(9)]),
            dedupedMicSegments: [seg(0, 10), seg(12, 30), seg(41, 42)])
        #expect(result == vec(0))
    }

    @Test("no surviving segments → nil")
    func noSegments() {
        let result = OwnerProfileLearner.ownerEmbedding(
            micDiarization: diarization(
                spans: [("SPEAKER_00", 0, 40)],
                embeddings: ["SPEAKER_00": vec(0)]),
            dedupedMicSegments: [])
        #expect(result == nil)
    }

    @Test("missing embedding for the dominant cluster → nil")
    func missingEmbedding() {
        let result = OwnerProfileLearner.ownerEmbedding(
            micDiarization: diarization(
                spans: [("SPEAKER_00", 0, 40)], embeddings: [:]),
            dedupedMicSegments: [seg(0, 10)])
        #expect(result == nil)
    }
}
