import Testing
@testable import PulsarTraceEngine

/// The pure "Restrict to languages" → FluidAudio script-hint mapping
/// (plan scope decision 3): exactly one allowed code becomes the hint;
/// zero or several codes mean auto (no hint).
@Suite("Parakeet language hint")
struct ParakeetLanguageHintTests {

    @Test func singleAllowedCodeBecomesTheHint() {
        #expect(ParakeetEngine.languageHint(from: ["pl"]) == "pl")
        #expect(ParakeetEngine.languageHint(from: ["EN"]) == "en")  // normalized
    }

    @Test func emptyListMeansAuto() {
        #expect(ParakeetEngine.languageHint(from: []) == nil)
    }

    @Test func multipleCodesMeanAuto() {
        // With several allowed languages the live pass cannot pick one —
        // scripts may differ per speaker; auto-detect handles it.
        #expect(ParakeetEngine.languageHint(from: ["en", "pl"]) == nil)
    }
}
