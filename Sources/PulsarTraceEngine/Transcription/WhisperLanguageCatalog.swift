import Foundation
import CWhisper

/// The set of languages whisper.cpp can detect/decode, surfaced for the
/// Settings UI's "Restrict to languages" multi-select.
///
/// whisper.cpp embeds a fixed table (≈99 entries) of language ids → short
/// codes (`whisper_lang_str`) and full names (`whisper_lang_str_full`). The
/// table is per-binary, not per-model — `whisper_lang_str` does not need a
/// loaded model or context, so the catalog can be built once at first
/// access without paying the model-load cost.
public enum WhisperLanguageCatalog {

    /// One whisper-known language. `code` is the ISO-639-1 short form the
    /// rest of the engine speaks (`WhisperOptions.allowedLanguages`,
    /// `--allowed-languages` flag); `displayName` is the human-readable name
    /// from whisper's own table, capitalised for the picker.
    public struct Language: Sendable, Equatable, Hashable, Identifiable {
        public let code: String
        public let displayName: String
        public var id: String { code }

        public init(code: String, displayName: String) {
            self.code = code
            self.displayName = displayName
        }
    }

    /// Every language whisper exposes, sorted alphabetically by display
    /// name (the order the user reads them in the dropdown). Built lazily
    /// on first access and memoised — the table is a static C lookup so a
    /// rebuild on every call would be wasted work.
    public static let all: [Language] = {
        let maxId = Int(whisper_lang_max_id())
        guard maxId >= 0 else { return [] }
        var out: [Language] = []
        out.reserveCapacity(maxId + 1)
        for id in 0...maxId {
            let idC = Int32(id)
            guard let codePtr = whisper_lang_str(idC) else { continue }
            let code = String(cString: codePtr)
            let displayName: String
            if let fullPtr = whisper_lang_str_full(idC) {
                displayName = String(cString: fullPtr).capitalized
            } else {
                displayName = code.uppercased()
            }
            out.append(Language(code: code, displayName: displayName))
        }
        return out.sorted { $0.displayName < $1.displayName }
    }()

    /// Look up a language by its short code (`"en"`, `"pl"`). `nil` when
    /// the code isn't in whisper's table — used by the migration of an
    /// older typed-string allow-list to filter out junk codes.
    public static func language(forCode code: String) -> Language? {
        let needle = code.lowercased()
        return all.first { $0.code == needle }
    }
}
