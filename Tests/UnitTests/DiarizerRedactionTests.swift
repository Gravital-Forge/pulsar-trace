import Testing
import Foundation
@testable import PulsarTraceEngine

/// Unit coverage of `Diarizer.redactingPaths` — the defensive basenaming of
/// diarization stderr/log text before it reaches the operational log
/// (S2 / PRD §11, R59).
///
/// Transitional: `redactingPaths` is a leftover surface only `LiveDiarizer`
/// still calls (rewritten in the next task, D40); this suite is deleted with
/// it. Until then it pins the redaction behaviour byte-for-byte.
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
