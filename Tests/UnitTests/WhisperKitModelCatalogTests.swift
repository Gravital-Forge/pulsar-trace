import Testing
@testable import PulsarTraceEngine

@Suite("WhisperKitModelCatalog")
struct WhisperKitModelCatalogTests {

    @Test func hasExactlyTheTwoANEModels() {
        #expect(WhisperKitModelCatalog.all.count == 2)
        #expect(WhisperKitModelCatalog.largeV3Turbo.name == "large-v3-turbo")
        #expect(WhisperKitModelCatalog.largeV3Turbo.variant
            == "openai_whisper-large-v3-v20240930_626MB")
        #expect(WhisperKitModelCatalog.largeV3.name == "large-v3-whisperkit")
        #expect(WhisperKitModelCatalog.largeV3.variant
            == "openai_whisper-large-v3_947MB")
    }

    @Test func lookupByName() {
        #expect(WhisperKitModelCatalog.model(named: "large-v3-turbo")
            == WhisperKitModelCatalog.largeV3Turbo)
        #expect(WhisperKitModelCatalog.model(named: "large-v3-whisperkit")
            == WhisperKitModelCatalog.largeV3)
        // Unknown names (including the retired whisper.cpp ones) → nil;
        // callers fall back to `defaultModel`.
        #expect(WhisperKitModelCatalog.model(named: "base") == nil)
        #expect(WhisperKitModelCatalog.model(named: "large-v3") == nil)
        #expect(WhisperKitModelCatalog.model(named: "parakeet-v3") == nil)
        #expect(WhisperKitModelCatalog.model(named: "") == nil)
    }

    @Test func turboIsTheDefaultAndListedFirst() {
        #expect(WhisperKitModelCatalog.defaultModel == WhisperKitModelCatalog.largeV3Turbo)
        // Picker/usage orderings read `all` — default first.
        #expect(WhisperKitModelCatalog.all.first == WhisperKitModelCatalog.largeV3Turbo)
    }
}
