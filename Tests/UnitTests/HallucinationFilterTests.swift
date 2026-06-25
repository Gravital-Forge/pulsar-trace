import Testing
@testable import PulsarTraceEngine

/// Unit coverage of the offline silence-hallucination filter (PT-P2-D13).
///
/// The load-bearing guarantee under test: a stock phrase is dropped ONLY when
/// an objective per-segment confidence signal also says the audio is silence.
/// The *same* stock phrase decoded with speech-range confidence is KEPT, so a
/// real person saying "Thank you." mid-meeting always survives.
@Suite("HallucinationFilter")
struct HallucinationFilterTests {

    /// A confidence reading that looks like genuine speech: low no_speech_prob,
    /// healthy avg logprob. Genuine offline-path speech decodes around here.
    private let speechConfidence = HallucinationFilter.SegmentConfidence(
        noSpeechProb: 0.05, avgLogProb: -0.25)

    /// A confidence reading that looks like silence: high no_speech_prob.
    private let silenceConfidence = HallucinationFilter.SegmentConfidence(
        noSpeechProb: 0.55, avgLogProb: -0.20)

    /// A confidence reading where no_speech_prob is fine but the decoder was
    /// clearly guessing — very negative avg logprob.
    private let lowConfidenceDecode = HallucinationFilter.SegmentConfidence(
        noSpeechProb: 0.10, avgLogProb: -1.40)

    @Test("Stock phrase on silence (high no_speech_prob) is dropped")
    func stockPhraseOnSilenceDropped() {
        #expect(HallucinationFilter.shouldDrop(
            text: "Thank you.", confidence: silenceConfidence))
        #expect(HallucinationFilter.shouldDrop(
            text: "Thanks for watching", confidence: silenceConfidence))
        #expect(HallucinationFilter.shouldDrop(
            text: "you", confidence: silenceConfidence))
    }

    @Test("Stock phrase on a low-confidence decode is dropped")
    func stockPhraseLowConfidenceDropped() {
        #expect(HallucinationFilter.shouldDrop(
            text: "Thank you.", confidence: lowConfidenceDecode))
    }

    /// The core safety guarantee: the SAME stock phrase, decoded with
    /// speech-range confidence, must be KEPT. A real "Thank you." survives.
    @Test("Stock phrase with speech-range confidence is KEPT")
    func stockPhraseWithSpeechKept() {
        #expect(!HallucinationFilter.shouldDrop(
            text: "Thank you.", confidence: speechConfidence))
        #expect(!HallucinationFilter.shouldDrop(
            text: "Thanks", confidence: speechConfidence))
        #expect(!HallucinationFilter.shouldDrop(
            text: "you", confidence: speechConfidence))
        #expect(!HallucinationFilter.shouldDrop(
            text: "Okay", confidence: speechConfidence))
    }

    @Test("Non-stock speech is always kept, even on a silence signal")
    func nonStockPhraseAlwaysKept() {
        #expect(!HallucinationFilter.shouldDrop(
            text: "So I was at the coffee shop this morning.",
            confidence: silenceConfidence))
        #expect(!HallucinationFilter.shouldDrop(
            text: "Let's circle back on the budget.",
            confidence: lowConfidenceDecode))
        // A real sentence that merely contains a stock phrase as a substring.
        #expect(!HallucinationFilter.shouldDrop(
            text: "Thank you for the detailed report.",
            confidence: silenceConfidence))
    }

    @Test("Case and punctuation variants of a stock phrase are recognized")
    func phraseVariantsRecognized() {
        // All of these normalize to "thank you" and, on silence, drop.
        for variant in ["Thank you.", "thank you", "THANK YOU!", "  Thank you  ",
                        "thank you?", "Thank you,"] {
            #expect(HallucinationFilter.shouldDrop(
                text: variant, confidence: silenceConfidence),
                "expected \"\(variant)\" to drop on silence")
            // ...and survive on speech-range confidence.
            #expect(!HallucinationFilter.shouldDrop(
                text: variant, confidence: speechConfidence),
                "expected \"\(variant)\" to be kept on speech")
        }
    }

    @Test("normalize lowercases, trims, strips surrounding punctuation")
    func normalizeStripsSurroundings() {
        #expect(HallucinationFilter.normalize("  Thank you. ") == "thank you")
        #expect(HallucinationFilter.normalize("THANK YOU!") == "thank you")
        #expect(HallucinationFilter.normalize("\"you\"") == "you")
        // Interior punctuation/spacing is preserved.
        #expect(HallucinationFilter.normalize("Well, hello.") == "well, hello")
    }

    @Test("Empty / whitespace text never drops")
    func emptyNeverDrops() {
        #expect(!HallucinationFilter.shouldDrop(
            text: "", confidence: silenceConfidence))
        #expect(!HallucinationFilter.shouldDrop(
            text: "   ", confidence: silenceConfidence))
    }
}
