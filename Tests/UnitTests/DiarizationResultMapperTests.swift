import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("DiarizationResultMapper")
struct DiarizationResultMapperTests {

    private func seg(_ id: String, _ start: Double, _ end: Double)
        -> DiarizationResultMapper.Segment {
        .init(speakerId: id, start: start, end: end)
    }

    @Test func mapsSegmentsAndEmbeddings() {
        let result = DiarizationResultMapper.map(
            segments: [seg("S1", 0.0, 4.5), seg("S2", 4.5, 9.0)],
            speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]],
            audioDuration: .seconds(9),
            modelRevision: "abc123")
        #expect(result.model == "FluidInference/speaker-diarization-coreml")
        #expect(result.modelRevision == "abc123")
        #expect(result.speakers == ["S1", "S2"])
        #expect(result.spans == [
            SpeakerSpan(speaker: "S1", start: .zero, end: .milliseconds(4500)),
            SpeakerSpan(speaker: "S2", start: .milliseconds(4500), end: .milliseconds(9000)),
        ])
        #expect(result.embeddings == [
            SpeakerEmbedding(speaker: "S1", vector: [1, 0, 0]),
            SpeakerEmbedding(speaker: "S2", vector: [0, 1, 0]),
        ])
    }

    @Test func speakersSortNaturally() {
        // "S10" must sort after "S2" (lexicographic would invert them, which
        // would scramble Speaker_N display labels past 9 speakers).
        let segments = (1...10).map { seg("S\($0)", Double($0), Double($0) + 1) }
        let result = DiarizationResultMapper.map(
            segments: segments, speakerDatabase: [:],
            audioDuration: .seconds(12), modelRevision: "")
        #expect(result.speakers == (1...10).map { "S\($0)" })
    }

    @Test func dropsNonFiniteAndOrphanEmbeddings() {
        // A NaN vector is dropped (mirrors the old Python sanitization);
        // an embedding for a label with no spans is dropped too.
        let result = DiarizationResultMapper.map(
            segments: [seg("S1", 0, 1)],
            speakerDatabase: ["S1": [Float.nan, 1], "S9": [1, 0]],
            audioDuration: .seconds(1), modelRevision: "")
        #expect(result.embeddings.isEmpty)
        #expect(result.speakers == ["S1"])
    }

    @Test func spansAreSortedByStart() {
        let result = DiarizationResultMapper.map(
            segments: [seg("S2", 5, 6), seg("S1", 0, 1)],
            speakerDatabase: [:],
            audioDuration: .seconds(6), modelRevision: "")
        #expect(result.spans.map(\.speaker) == ["S1", "S2"])
    }
}
