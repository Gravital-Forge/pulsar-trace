import Foundation
import Testing
@testable import PulsarTraceMenuBar

/// Parser for the stable `**[HH:MM:SS] Speaker:** text` transcript line
/// shape (live.md/final.md public contract — `.erratum/product/architecture/transcript-format.md`).
@Suite("TranscriptLine parser")
struct TranscriptLineTests {

    @Test("an utterance line parses into timestamp, speaker, text")
    func utterance() {
        let kind = TranscriptLine.parse("**[00:01:23] Steve:** hello there")
        #expect(kind == .utterance(timestamp: "00:01:23", speaker: "Steve", text: "hello there"))
    }

    @Test("a provisional live label keeps its ? suffix in the speaker field")
    func provisionalSpeaker() {
        let kind = TranscriptLine.parse("**[00:00:05] Them?:** hi")
        #expect(kind == .utterance(timestamp: "00:00:05", speaker: "Them?", text: "hi"))
    }

    @Test("speaker names containing colons survive (greedy up to the last ':**')")
    func colonInSpeaker() {
        let kind = TranscriptLine.parse("**[00:00:05] Dr. Who: The Second:** text")
        #expect(kind == .utterance(timestamp: "00:00:05", speaker: "Dr. Who: The Second", text: "text"))
    }

    @Test("the document marker is recognized")
    func marker() {
        #expect(TranscriptLine.parse("<!-- pulsartrace:final -->") == .marker)
        #expect(TranscriptLine.parse("<!-- pulsartrace:live -->") == .marker)
    }

    @Test("the H2 header is recognized with its text")
    func header() {
        #expect(TranscriptLine.parse("## Transcript — 2026-05-16 14:30")
            == .header("Transcript — 2026-05-16 14:30"))
    }

    @Test("blank and unrecognized lines fall through")
    func fallthroughs() {
        #expect(TranscriptLine.parse("") == .blank)
        #expect(TranscriptLine.parse("   ") == .blank)
        #expect(TranscriptLine.parse("not a transcript line") == .plain("not a transcript line"))
        #expect(TranscriptLine.parse("**[bad] Steve:** x") == .plain("**[bad] Steve:** x"))
    }

    @Test("empty utterance text is allowed")
    func emptyText() {
        let kind = TranscriptLine.parse("**[00:00:01] You:** ")
        #expect(kind == .utterance(timestamp: "00:00:01", speaker: "You", text: ""))
    }
}
