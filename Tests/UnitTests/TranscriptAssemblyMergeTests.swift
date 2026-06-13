import Foundation
import Testing
@testable import PulsarTraceEngine

/// Coverage of `TranscriptAssembly.mergeStreams`' distinct-speaker list — the
/// list that becomes `metadata.json`'s `speakers` array and the recordings-list
/// speaker pills.
///
/// The `Unrecognized` sentinel (`DiarizationMerge.unknownSpeaker`) labels lines
/// that overlap no diarized span so no text is lost, but it is **not a real
/// speaker** — it must never earn a row in the speaker summary.
@Suite("TranscriptAssembly merge — distinct speakers")
struct TranscriptAssemblyMergeTests {

    private static let start = Date(timeIntervalSince1970: 1_777_000_000)

    private func seg(_ s: Double, _ e: Double, _ t: String) -> TranscriptSegment {
        TranscriptSegment(
            start: .milliseconds(Int(s * 1000)),
            end: .milliseconds(Int(e * 1000)),
            text: t)
    }

    /// One diarized speaker spanning 0–5 s; everything after is no-overlap.
    private func oneSpeakerDiarization() -> DiarizationResult {
        DiarizationResult(
            model: "test",
            audioDuration: .seconds(14),
            speakers: ["S1"],
            spans: [SpeakerSpan(speaker: "S1", start: .zero, end: .seconds(5))],
            embeddings: [])
    }

    @Test("No-overlap lines do not add Unrecognized to the speaker list")
    func unrecognizedExcludedFromSpeakerList() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [
                seg(1, 4, "Overlaps the diarized speaker."),
                seg(10, 13, "Falls outside every diarized span."),
            ],
            diarization: oneSpeakerDiarization(),
            reconciliation: nil,
            micSegments: nil,
            recordingStart: Self.start)

        // The summary lists only the real speaker — never the sentinel.
        #expect(merged.speakers == ["Speaker_0"])
        #expect(!merged.speakers.contains(DiarizationMerge.unknownSpeaker))

        // …but the no-overlap line is still labelled, so no text is lost.
        #expect(merged.document.render().contains(
            "] \(DiarizationMerge.unknownSpeaker):**"))
    }

    @Test("Skipped diarization yields an empty speaker list, not Unrecognized")
    func skippedDiarizationHasNoPhantomSpeaker() {
        // diarization == nil → every system line is `Unrecognized`. The speaker
        // summary must be empty rather than a lone phantom "Unrecognized" pill.
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [seg(0, 4, "Some speech, no diarization available.")],
            diarization: nil,
            reconciliation: nil,
            micSegments: nil,
            recordingStart: Self.start)

        #expect(merged.speakers.isEmpty)
    }

    @Test("The mic speaker survives alongside excluded Unrecognized lines")
    func micSpeakerSurvives() {
        let merged = TranscriptAssembly.mergeStreams(
            systemSegments: [seg(10, 13, "Unrecognized system line.")],
            diarization: oneSpeakerDiarization(),
            reconciliation: nil,
            micSegments: [seg(1, 4, "Local user.")],
            recordingStart: Self.start)

        #expect(merged.speakers == ["You"])
    }
}
