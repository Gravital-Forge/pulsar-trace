import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `DiarizationMerge` — merging whisper utterances with
/// pyannote speaker spans by timestamp overlap.
///
/// Pure logic over hand-built `DiarizationResult`s (and the committed JSON
/// fixtures); no subprocess, no model. The Pipeline suite snapshot-tests the
/// rendered markdown end to end.
@Suite("Diarization merge (transcript ⨉ spans)")
struct DiarizationMergeTests {

    private static let start = Date(timeIntervalSince1970: 1_777_000_000)

    /// Build a `DiarizationResult` from raw `(speaker, start, end)` tuples.
    private func result(
        speakers: [String],
        spans: [(String, Double, Double)]
    ) -> DiarizationResult {
        DiarizationResult(
            model: "pyannote/speaker-diarization-community-1",
            modelVersion: "4.0.4",
            audioDuration: .seconds(60),
            speakers: speakers,
            spans: spans.map {
                SpeakerSpan(
                    speaker: $0.0,
                    start: .milliseconds(Int($0.1 * 1000)),
                    end: .milliseconds(Int($0.2 * 1000)))
            },
            exclusiveSpans: [],
            embeddings: []
        )
    }

    private func segment(_ start: Double, _ end: Double, _ text: String)
        -> TranscriptSegment
    {
        TranscriptSegment(
            start: .milliseconds(Int(start * 1000)),
            end: .milliseconds(Int(end * 1000)),
            text: text)
    }

    @Test("Each utterance is attributed to its dominant-overlap speaker")
    func dominantOverlapAttribution() {
        let diar = result(
            speakers: ["SPEAKER_00", "SPEAKER_01"],
            spans: [
                ("SPEAKER_00", 0, 10),
                ("SPEAKER_01", 10, 20),
            ])
        let segments = [
            segment(1, 4, "first speaker talks"),
            segment(12, 18, "second speaker talks"),
        ]
        let labels = DiarizationMerge.speakerLabels(for: segments, diarization: diar)
        #expect(labels == ["Speaker_0", "Speaker_1"])
    }

    @Test("An utterance straddling a turn boundary takes the larger overlap")
    func straddlingUtteranceTakesLargerOverlap() {
        let diar = result(
            speakers: ["SPEAKER_00", "SPEAKER_01"],
            spans: [
                ("SPEAKER_00", 0, 10),
                ("SPEAKER_01", 10, 20),
            ])
        // 9–13: 1s with Speaker_0, 3s with Speaker_1 → Speaker_1 dominates.
        let labels = DiarizationMerge.speakerLabels(
            for: [segment(9, 13, "boundary")], diarization: diar)
        #expect(labels == ["Speaker_1"])
    }

    @Test("Overlapping speech co-attributes both speakers")
    func overlappingSpeechCoAttributed() {
        // Both speakers active across the whole utterance.
        let diar = result(
            speakers: ["SPEAKER_00", "SPEAKER_01"],
            spans: [
                ("SPEAKER_00", 0, 10),
                ("SPEAKER_01", 0, 10),
            ])
        let labels = DiarizationMerge.speakerLabels(
            for: [segment(2, 8, "talked over")], diarization: diar)
        #expect(labels == ["Speaker_0+Speaker_1"])
    }

    @Test("A brief incidental overlap does not co-attribute")
    func briefOverlapNotCoAttributed() {
        // Speaker_1 covers only ~0.5s of a 6s utterance — below the 0.30
        // share threshold, so it is not co-attributed.
        let diar = result(
            speakers: ["SPEAKER_00", "SPEAKER_01"],
            spans: [
                ("SPEAKER_00", 0, 20),
                ("SPEAKER_01", 7.5, 8.0),
            ])
        let labels = DiarizationMerge.speakerLabels(
            for: [segment(2, 8, "mostly one speaker")], diarization: diar)
        #expect(labels == ["Speaker_0"])
    }

    @Test("An utterance overlapping no span keeps the unknown label")
    func noOverlapKeepsUnknown() {
        let diar = result(
            speakers: ["SPEAKER_00"],
            spans: [("SPEAKER_00", 0, 5)])
        let labels = DiarizationMerge.speakerLabels(
            for: [segment(30, 35, "speech with no diarized span")],
            diarization: diar)
        #expect(labels == [DiarizationMerge.unknownSpeaker])
    }

    @Test("Merge is deterministic: same inputs → identical labels")
    func mergeIsDeterministic() throws {
        let diar = try DiarizationDecoder.decode(
            DiarizationFixtureLocator.data("two-speakers-alternating.json"))
        let segments = [
            segment(1, 5, "a"), segment(10, 12, "b"), segment(14, 20, "c"),
        ]
        let first = DiarizationMerge.speakerLabels(for: segments, diarization: diar)
        let second = DiarizationMerge.speakerLabels(for: segments, diarization: diar)
        #expect(first == second)
    }

    @Test("Diarized document carries real Speaker_N labels, not the placeholder")
    func diarizedDocumentReplacesPlaceholder() throws {
        let diar = try DiarizationDecoder.decode(
            DiarizationFixtureLocator.data("two-speakers-alternating.json"))
        // Spans: SPEAKER_00 ~0–12.5, SPEAKER_01 ~13–24.
        let segments = [
            segment(1, 5, "Hello there everyone."),
            segment(14, 20, "Good to be here."),
        ]
        let doc = DiarizationMerge.diarizedDocument(
            recordingStart: Self.start, segments: segments, diarization: diar)
        let rendered = doc.render()

        #expect(rendered.contains("] Speaker_0:**"))
        #expect(rendered.contains("] Speaker_1:**"))
        // The Epic 2 placeholder must be gone.
        #expect(!rendered.contains("] Speaker:**"))
    }
}
