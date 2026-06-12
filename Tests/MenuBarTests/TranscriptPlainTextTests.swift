import Testing
@testable import PulsarTraceMenuBar

@Suite("TranscriptPlainText")
struct TranscriptPlainTextTests {

    @Test("renders utterances as displayed, drops markers and blanks")
    func rendered() {
        let lines = [
            "<!-- pulsartrace:final -->",
            "## Transcript — 2026-05-01 09:00",
            "",
            "**[00:00:03] Them?:** Morning everyone.",
            "",
            "**[00:00:09] You:** Hi.",
        ]
        #expect(TranscriptPlainText.rendered(from: lines) == """
        Transcript — 2026-05-01 09:00
        [00:00:03] Them?  Morning everyone.
        [00:00:09] You  Hi.
        """)
    }

    @Test("unparseable lines pass through verbatim")
    func passthrough() {
        #expect(TranscriptPlainText.rendered(from: ["just prose"]) == "just prose")
    }
}
