import Testing
import Foundation
@testable import PulsarTraceEngine

/// Coverage of `WhisperLanguageCatalog` — the catalog the Settings UI's
/// "Restrict to languages" picker reads. Catalog values come straight out of
/// whisper.cpp's static language table; we only assert shape, sort order,
/// and that the codes the user typically picks are present.
@Suite("Whisper language catalog")
struct WhisperLanguageCatalogTests {

    @Test("the catalog is non-empty and covers whisper's full table")
    func nonEmpty() {
        // whisper.cpp ships ≈99 language ids; assert a generous floor so a
        // regression that truncates the loop is loud, but the exact count is
        // pinned to whisper's vendor — we don't reproduce it here.
        #expect(WhisperLanguageCatalog.all.count >= 90)
    }

    @Test("every entry has a non-empty lowercase code and a non-empty display name")
    func wellFormedEntries() {
        for lang in WhisperLanguageCatalog.all {
            #expect(!lang.code.isEmpty, "empty code in \(lang)")
            #expect(lang.code == lang.code.lowercased(),
                    "code should be lowercase: \(lang.code)")
            #expect(!lang.displayName.isEmpty, "empty name in \(lang)")
        }
    }

    @Test("entries are sorted by display name (alphabetical, picker-ready)")
    func sortedByDisplayName() {
        let names = WhisperLanguageCatalog.all.map(\.displayName)
        #expect(names == names.sorted(),
                "catalog must already be sorted; got \(names.prefix(10))…")
    }

    @Test("the catalog contains the codes the user actually picks")
    func commonCodesPresent() {
        // Spot-check the codes named in the original ask — if these vanish
        // from whisper, the picker would silently drop the user's selection.
        let codes = Set(WhisperLanguageCatalog.all.map(\.code))
        for code in ["en", "pl", "de", "fr", "es", "it"] {
            #expect(codes.contains(code), "missing common code: \(code)")
        }
    }

    @Test("language(forCode:) resolves a known code and rejects junk")
    func lookupByCode() {
        let en = WhisperLanguageCatalog.language(forCode: "en")
        #expect(en?.code == "en")
        // Case-insensitive: a stored "EN" still resolves.
        #expect(WhisperLanguageCatalog.language(forCode: "EN")?.code == "en")
        // Unknown returns nil — the migration relies on this filter.
        #expect(WhisperLanguageCatalog.language(forCode: "xx") == nil)
    }

    @Test("codes are unique — no two entries share the same code")
    func codesUnique() {
        let codes = WhisperLanguageCatalog.all.map(\.code)
        #expect(codes.count == Set(codes).count, "duplicate codes in catalog")
    }
}
