import Testing
import Foundation
@testable import PulsarTraceEngine

/// Coverage of `LanguageCatalog` — the catalog the Settings UI's
/// "Restrict to languages" picker and `refine --language` validation read.
/// Values come from WhisperKit's static language table; we assert shape,
/// sort order, and that the codes the user typically picks are present.
@Suite("Language catalog")
struct LanguageCatalogTests {

    @Test("the catalog is non-empty and covers whisper's full table")
    func nonEmpty() {
        // Whisper ships ≈99 languages; assert a generous floor so a
        // truncation regression is loud without pinning the vendor's count.
        #expect(LanguageCatalog.all.count >= 90)
    }

    @Test("every entry has a non-empty lowercase code and a non-empty display name")
    func wellFormedEntries() {
        for lang in LanguageCatalog.all {
            #expect(!lang.code.isEmpty, "empty code in \(lang)")
            #expect(lang.code == lang.code.lowercased(),
                    "code should be lowercase: \(lang.code)")
            #expect(!lang.displayName.isEmpty, "empty display name for \(lang.code)")
        }
    }

    @Test("entries are sorted by display name")
    func sortedByDisplayName() {
        let names = LanguageCatalog.all.map(\.displayName)
        #expect(names == names.sorted())
    }

    @Test("the catalog contains the codes the user actually picks")
    func commonCodesPresent() {
        // Spot-check the codes named in the original ask — if these vanish
        // from the vendor table, the picker would silently drop a selection.
        let codes = Set(LanguageCatalog.all.map(\.code))
        for code in ["en", "pl", "de", "fr", "es", "it"] {
            #expect(codes.contains(code), "missing common code: \(code)")
        }
    }

    @Test("codes are unique — no two entries share the same code")
    func codesUnique() {
        let codes = LanguageCatalog.all.map(\.code)
        #expect(codes.count == Set(codes).count, "duplicate codes in catalog")
    }

    @Test("the user's languages are present and look up by code")
    func commonLookups() {
        #expect(LanguageCatalog.language(forCode: "en")?.displayName == "English")
        #expect(LanguageCatalog.language(forCode: "pl")?.displayName == "Polish")
        #expect(LanguageCatalog.language(forCode: "PL")?.code == "pl")  // case-folded
        #expect(LanguageCatalog.language(forCode: "zz") == nil)
    }
}
