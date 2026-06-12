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
}
