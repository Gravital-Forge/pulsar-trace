import Testing
@testable import PulsarTraceEngine

/// Unit coverage of the whisper blank/hallucination filter (Epic 2 edge case:
/// silence must not produce text).
@Suite("BlankTokenFilter")
struct BlankTokenFilterTests {

    @Test("Empty and whitespace-only text is blank")
    func emptyIsBlank() {
        #expect(BlankTokenFilter.isBlank(""))
        #expect(BlankTokenFilter.isBlank("   "))
        #expect(BlankTokenFilter.isBlank("\n\t "))
    }

    @Test("Bracketed non-speech markers are blank")
    func bracketedMarkers() {
        #expect(BlankTokenFilter.isBlank("[BLANK_AUDIO]"))
        #expect(BlankTokenFilter.isBlank("[blank_audio]"))
        #expect(BlankTokenFilter.isBlank("(silence)"))
        #expect(BlankTokenFilter.isBlank("[ Silence ]"))
        #expect(BlankTokenFilter.isBlank("*music*"))
        #expect(BlankTokenFilter.isBlank("(applause)"))
    }

    @Test("Stock silence hallucinations are blank")
    func silenceHallucinations() {
        #expect(BlankTokenFilter.isBlank("Thanks for watching"))
        #expect(BlankTokenFilter.isBlank("thanks for watching!"))
        #expect(BlankTokenFilter.isBlank("Thank you for watching"))
        #expect(BlankTokenFilter.isBlank("Please subscribe"))
        #expect(BlankTokenFilter.isBlank("you"))
        #expect(BlankTokenFilter.isBlank("."))
    }

    @Test("Genuine speech is NOT blank — even when it contains a filtered word")
    func genuineSpeechSurvives() {
        #expect(!BlankTokenFilter.isBlank("So I was at the coffee shop this morning."))
        // "thanks for watching" appears only as a substring of real speech.
        #expect(!BlankTokenFilter.isBlank(
            "She said thanks for watching the kids while she was out."))
        #expect(!BlankTokenFilter.isBlank("Thank you so much for the detailed report."))
        // A bracketed phrase that is real content, not a marker, survives.
        #expect(!BlankTokenFilter.isBlank("[see the attached design doc]"))
    }

    /// Meeting-closing utterances must survive — this is a meeting transcription
    /// product, and trailing-punctuation normalization means a bare "Thank you."
    /// or "Bye!" must not be confused with a YouTube hallucination.
    @Test("Meeting-closing 'Thank you'/'Bye' are NOT blank")
    func meetingClosingsSurvive() {
        #expect(!BlankTokenFilter.isBlank("Thank you."))
        #expect(!BlankTokenFilter.isBlank("Thank you"))
        #expect(!BlankTokenFilter.isBlank("thank you!"))
        #expect(!BlankTokenFilter.isBlank("Bye!"))
        #expect(!BlankTokenFilter.isBlank("bye"))
        // ...while the unambiguous YouTube-only phrase still IS filtered.
        #expect(BlankTokenFilter.isBlank("thanks for watching"))
        #expect(BlankTokenFilter.isBlank("Thanks for watching."))
    }
}
