import Foundation
import WhisperKit

/// The languages the transcription stack can decode/detect, surfaced for
/// the Settings UI's "Restrict to languages" multi-select and
/// `refine --language` validation.
///
/// Built from WhisperKit's language table (verified public, v1.0.0
/// `Models.swift:1327`: `@frozen public enum Constants { public static let
/// languages: [String: String] }`, display name → ISO-639-1 code, 99
/// entries) — the same fixed table whisper.cpp embedded, with no model
/// load required. Replaces the CWhisper-backed `WhisperLanguageCatalog`.
public enum LanguageCatalog {

    /// One known language. `code` is the ISO-639-1 short form the rest of
    /// the engine speaks (`WhisperOptions.allowedLanguages`,
    /// `--allowed-languages`, `refine --language`); `displayName` is
    /// capitalised for the picker.
    public struct Language: Sendable, Equatable, Hashable, Identifiable {
        public let code: String
        public let displayName: String
        public var id: String { code }

        public init(code: String, displayName: String) {
            self.code = code
            self.displayName = displayName
        }
    }

    /// Every language, one row per ISO code, sorted alphabetically by
    /// display name (the order the user reads them in the dropdown). Built
    /// once — static table.
    ///
    /// WhisperKit's table is keyed by display name and carries alias rows
    /// that collapse to one code (`"flemish"`/`"dutch"` → `nl`,
    /// `"mandarin"`/`"chinese"` → `zh`, `"burmese"`/`"myanmar"` → `my`, …) —
    /// 112 names, 100 codes. The picker writes a per-code toggle and looks
    /// up by code, so we de-duplicate to one canonical name per code
    /// (the alphabetically-first name, chosen deterministically) to keep
    /// the catalog's codes unique like the old whisper.cpp table.
    public static let all: [Language] = {
        let canonical = Dictionary(
            Constants.languages.map { ($0.value, $0.key.capitalized) },
            uniquingKeysWith: { lhs, rhs in lhs < rhs ? lhs : rhs })
        return canonical
            .map { Language(code: $0.key, displayName: $0.value) }
            .sorted { $0.displayName < $1.displayName }
    }()

    /// Look up a language by its short code (`"en"`, `"pl"`). `nil` when
    /// the code isn't in the table.
    public static func language(forCode code: String) -> Language? {
        let needle = code.lowercased()
        return all.first { $0.code == needle }
    }
}
