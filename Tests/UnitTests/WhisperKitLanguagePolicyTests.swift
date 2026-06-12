import Testing
@testable import PulsarTraceEngine

@Suite("WhisperKitLanguagePolicy")
struct WhisperKitLanguagePolicyTests {

    @Test func explicitLanguageBeatsTheAllowList() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: "pl", allowed: ["en", "de"])
            == .pin("pl"))
    }

    @Test func explicitPassesThroughEvenWhenNotInTheAllowedList() {
        // `refine --language` is an operator override — it wins outright,
        // it is not filtered through the Settings allow-list.
        #expect(WhisperKitLanguagePolicy.resolve(explicit: "ja", allowed: ["en", "pl"])
            == .pin("ja"))
    }

    @Test func singleAllowedCodePins() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["pl"])
            == .pin("pl"))
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["EN"])
            == .pin("en"))   // normalized
    }

    @Test func multipleAllowedCodesDetectAmong() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["en", "pl"])
            == .detectAmong(["en", "pl"]))
    }

    @Test func nothingMeansAuto() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: []) == .auto)
    }

    @Test func explicitIsTrimmedAndNormalized() {
        #expect(WhisperKitLanguagePolicy.resolve(explicit: " PL ", allowed: [])
            == .pin("pl"))
        // Whitespace-only explicit falls through to the allow-list rules.
        #expect(WhisperKitLanguagePolicy.resolve(explicit: "  ", allowed: ["en"])
            == .pin("en"))
    }

    @Test func allowedListIsSanitized() {
        // Lowercasing + dropping empties collapses to one code → pin.
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["en", "EN", ""])
            == .pin("en"))
        // Order-preserving dedupe keeps first-seen order.
        #expect(WhisperKitLanguagePolicy.resolve(explicit: nil, allowed: ["EN", "pl", "en"])
            == .detectAmong(["en", "pl"]))
    }
}
