import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of the Swift↔Python diarization JSON contract decoding
/// (`DiarizationDecoder`) and the `DiarizationResult` label mapping.
///
/// Uses the committed `Tests/Fixtures/diarization/*.json` fixtures, which were
/// generated once from real pyannote (Epic 3). No subprocess, no model load —
/// these are pure decoding tests, well under the Unit budget.
@Suite("Diarization JSON decoding")
struct DiarizationDecodeTests {

    @Test("Decodes the two-speaker fixture: 2 speakers, spans, 256-d embeddings")
    func decodesTwoSpeakerFixture() throws {
        let data = try DiarizationFixtureLocator.data("two-speakers-alternating.json")
        let result = try DiarizationDecoder.decode(data)

        #expect(result.model == "pyannote/speaker-diarization-community-1")
        #expect(!result.modelVersion.isEmpty)
        #expect(result.speakers == ["SPEAKER_00", "SPEAKER_01"])
        #expect(result.spans.count >= 2)
        #expect(result.exclusiveSpans.count >= 1)

        // R29: per-speaker embeddings, 256-d, one per speaker.
        #expect(result.embeddings.count == 2)
        for embedding in result.embeddings {
            #expect(embedding.vector.count == 256)
        }

        // Spans are time-ordered and non-degenerate.
        for span in result.spans {
            #expect(span.end > span.start)
        }
    }

    @Test("Decodes the single-speaker fixture: exactly 1 speaker, no ghosts")
    func decodesSingleSpeakerFixture() throws {
        let data = try DiarizationFixtureLocator.data("single-speaker-30s.json")
        let result = try DiarizationDecoder.decode(data)

        #expect(result.speakers == ["SPEAKER_00"])
        #expect(result.embeddings.count == 1)
        #expect(result.spans.allSatisfy { $0.speaker == "SPEAKER_00" })
    }

    @Test("Decodes the overlap fixture: spans of two speakers overlap in time")
    func decodesOverlapFixture() throws {
        let data = try DiarizationFixtureLocator.data("two-speakers-overlap.json")
        let result = try DiarizationDecoder.decode(data)

        #expect(result.speakers.count == 2)

        // At least one pair of different-speaker spans overlaps in time.
        var foundOverlap = false
        for (i, a) in result.spans.enumerated() {
            for b in result.spans[(i + 1)...] where a.speaker != b.speaker {
                let lo = max(a.start.seconds, b.start.seconds)
                let hi = min(a.end.seconds, b.end.seconds)
                if hi > lo { foundOverlap = true }
            }
        }
        #expect(foundOverlap)
    }

    @Test("Display labels map raw pyannote labels to Speaker_N positionally")
    func displayLabelMapping() throws {
        let data = try DiarizationFixtureLocator.data("two-speakers-alternating.json")
        let result = try DiarizationDecoder.decode(data)

        #expect(result.displayLabel(for: "SPEAKER_00") == "Speaker_0")
        #expect(result.displayLabel(for: "SPEAKER_01") == "Speaker_1")
        // An unknown label falls back to itself — no text is ever dropped.
        #expect(result.displayLabel(for: "SPEAKER_99") == "SPEAKER_99")
    }

    @Test("An unsupported schema version is rejected, not mis-decoded")
    func rejectsUnsupportedSchema() throws {
        let json = #"""
        {"schema":999,"model":"x","model_version":"4.0.4","audio_duration":1.0,
         "speakers":[],"spans":[],"exclusive_spans":[],"embeddings":{},
         "embedding_dim":0}
        """#
        #expect(throws: DiarizationDecoder.DecodeError.self) {
            _ = try DiarizationDecoder.decode(Data(json.utf8))
        }
    }

    @Test("Malformed JSON surfaces a clean decode error")
    func rejectsMalformedJSON() {
        #expect(throws: DiarizationDecoder.DecodeError.self) {
            _ = try DiarizationDecoder.decode(Data("not json".utf8))
        }
    }

    @Test("model_revision decodes; absent revision is tolerated (additive field)")
    func decodesModelRevision() throws {
        let data = try DiarizationFixtureLocator.data("two-speakers-alternating.json")
        let result = try DiarizationDecoder.decode(data)
        // Regenerated Epic-3 fixtures carry the HF checkpoint commit SHA.
        #expect(!result.modelRevision.isEmpty)

        // A blob from an older Python build (no model_revision) still decodes
        // — the field is optional, schema stays 1.
        let legacy = #"""
        {"schema":1,"model":"m","model_version":"4.0.4","audio_duration":1.0,
         "speakers":[],"spans":[],"exclusive_spans":[],"embeddings":{},
         "embedding_dim":0}
        """#
        let legacyResult = try DiarizationDecoder.decode(Data(legacy.utf8))
        #expect(legacyResult.modelRevision == "")
    }
}

/// Unit coverage of `Diarizer.redactingPaths` — the defensive basenaming of
/// Python stderr before it reaches the operational log (S2 / PRD §11, R59).
@Suite("Diarizer stderr path redaction")
struct DiarizerRedactionTests {

    @Test("An absolute path token is reduced to its basename")
    func redactsAbsolutePath() {
        let line = "[diarize] error: /Users/alice/Meetings/secret.wav not found"
        let out = Diarizer.redactingPaths(in: line)
        #expect(out == "[diarize] error: secret.wav not found")
        #expect(!out.contains("/Users/alice"))
    }

    @Test("Non-path text and a bare slash are left untouched")
    func leavesNonPathsAlone() {
        #expect(Diarizer.redactingPaths(in: "2 speakers, dim=256") == "2 speakers, dim=256")
        #expect(Diarizer.redactingPaths(in: "ratio 3/4 ok") == "ratio 3/4 ok")
        #expect(Diarizer.redactingPaths(in: "/") == "/")
    }
}
