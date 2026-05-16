import Testing
import Foundation
import SnapshotTesting
@testable import PulsarTraceEngine

/// Pipeline coverage of the transcript ⨉ diarization merge (R15a, R29).
///
/// This snapshot-tests the merged `Speaker_N` markdown. It consumes the
/// **committed** diarization JSON fixture (`Tests/Fixtures/diarization/…`),
/// generated once from real pyannote — it does **not** run pyannote. Running
/// the model (~10–30s load) inside every `swift test --filter Pipeline` would
/// blow the ~30s budget; real pyannote correctness is verified in the `pytest`
/// suite and by `DiarizationE2ETests` (filterable, opt-in).
///
/// Determinism (PRD §12): the fixture is committed and never regenerated at
/// test time, and the merge is pure — so the snapshot is stable across runs.
@Suite("Diarization merge pipeline (R15a/R29)")
struct DiarizationMergePipelineTests {

    /// A fixed wall-clock start so the document header is deterministic.
    private static let start = Date(timeIntervalSince1970: 1_777_000_000)

    /// Body of a rendered transcript with the wall-clock header replaced by a
    /// stable placeholder (same approach as `TranscriptionPipelineTests`).
    private func body(of markdown: String) -> String {
        var lines = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.count > 1 { lines[1] = "## Transcript — <recording-start>" }
        return lines.joined(separator: "\n")
    }

    /// A synthetic two-speaker transcript whose timings line up with the
    /// `two-speakers-alternating.json` fixture (SPEAKER_00 ≈ 0–12.5s,
    /// SPEAKER_01 ≈ 13–24s). Hand-built so the merge — not whisper — is what
    /// this suite exercises.
    private func alternatingSegments() -> [TranscriptSegment] {
        func seg(_ s: Double, _ e: Double, _ t: String) -> TranscriptSegment {
            TranscriptSegment(
                start: .milliseconds(Int(s * 1000)),
                end: .milliseconds(Int(e * 1000)),
                text: t)
        }
        return [
            seg(0.5, 4.0, "So the main issue is the auth flow."),
            seg(9.5, 12.0, "It breaks on the redirect."),
            seg(13.5, 19.0, "Right, the redirect URI isn't handled."),
            seg(20.0, 23.5, "I can take a look this afternoon."),
        ]
    }

    @Test("Two-speaker merge renders stable Speaker_N markdown")
    func twoSpeakerMergeSnapshot() throws {
        let diarization = try DiarizationDecoder.decode(
            FixtureLocator.diarizationData("two-speakers-alternating.json"))
        let document = DiarizationMerge.diarizedDocument(
            recordingStart: Self.start,
            segments: alternatingSegments(),
            diarization: diarization)

        let markdown = document.render()
        // Real diarized labels replace the Epic 2 placeholder.
        #expect(markdown.contains("] Speaker_0:**"))
        #expect(markdown.contains("] Speaker_1:**"))
        #expect(!markdown.contains("] Speaker:**"))

        assertSnapshot(of: body(of: markdown), as: .lines)
    }

    @Test("Merged markdown is byte-identical across repeated merges")
    func mergeIsStableAcrossRuns() throws {
        let diarization = try DiarizationDecoder.decode(
            FixtureLocator.diarizationData("two-speakers-alternating.json"))
        let segments = alternatingSegments()

        func mergeOnce() -> String {
            DiarizationMerge.diarizedDocument(
                recordingStart: Self.start,
                segments: segments,
                diarization: diarization).render()
        }
        #expect(mergeOnce() == mergeOnce())
    }

    @Test("Single-speaker recording yields one speaker label, no ghosts")
    func singleSpeakerMerge() throws {
        let diarization = try DiarizationDecoder.decode(
            FixtureLocator.diarizationData("single-speaker-30s.json"))
        let segments = [
            TranscriptSegment(start: .seconds(1), end: .seconds(5),
                              text: "Just me talking here."),
            TranscriptSegment(start: .seconds(10), end: .seconds(14),
                              text: "Still just me."),
        ]
        let labels = DiarizationMerge.speakerLabels(
            for: segments, diarization: diarization)
        #expect(Set(labels) == ["Speaker_0"])
    }
}
