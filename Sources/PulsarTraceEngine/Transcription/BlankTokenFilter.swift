import Foundation

/// Filters whisper's blank / silence / hallucinated-on-silence output.
///
/// whisper is built `suppress_blank`/`suppress_nst` at the decoder, but it
/// still occasionally emits a bracketed marker like `[BLANK_AUDIO]`, a bare
/// musical note, or — on long silence — a stock hallucination ("thanks for
/// watching", "please subscribe"). Those are not real utterances and must not
/// reach `final.md`. The governing rule: silence must yield no text.
///
/// The filter is intentionally conservative: it only drops a segment when the
/// *entire* segment is a known marker or a known full-segment hallucination, so
/// it never truncates genuine speech that merely contains one of these words.
public enum BlankTokenFilter {

    /// Bracketed non-speech markers whisper emits, matched case-insensitively
    /// as the whole segment (e.g. `[BLANK_AUDIO]`, `(silence)`, `*music*`).
    private static let bracketedMarkers: Set<String> = [
        "blank_audio", "blank audio", "silence", "music", "inaudible",
        "no audio", "no speech", "background noise", "applause", "laughter",
    ]

    /// Stock phrases whisper hallucinates over long silence. Matched only as a
    /// whole (normalized) segment — never as a substring of real speech.
    ///
    /// Deliberately YouTube-only: phrases like `"thank you"` and `"bye"` are
    /// excluded because they are legitimate, common meeting-closing utterances
    /// — and with trailing-punctuation normalization `"Thank you."` / `"Bye!"`
    /// would otherwise be dropped. We only filter phrases that have no place in
    /// a real meeting transcript.
    private static let silenceHallucinations: Set<String> = [
        "thanks for watching",
        "thank you for watching",
        "thanks for watching!",
        "please subscribe",
        "please subscribe to my channel",
        "you",
        ".",
    ]

    /// True when `text` is empty, a non-speech marker, or a stock silence
    /// hallucination — i.e. should be dropped from the transcript.
    public static func isBlank(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        // A segment wrapped entirely in [] / () / ** is a marker; check its core.
        let core = strippedWrapper(trimmed).lowercased()
        if core.isEmpty { return true }
        if wasWrapped(trimmed), bracketedMarkers.contains(core) { return true }

        // Whole-segment stock hallucinations.
        let normalized = trimmed
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t.!?,"))
        if normalized.isEmpty { return true }
        if silenceHallucinations.contains(trimmed.lowercased()) { return true }
        if silenceHallucinations.contains(normalized) { return true }

        return false
    }

    /// True if `text` is fully enclosed in matching `[]`, `()` or `**`.
    private static func wasWrapped(_ text: String) -> Bool {
        guard let f = text.first, let l = text.last else { return false }
        return (f == "[" && l == "]") || (f == "(" && l == ")")
            || (text.hasPrefix("*") && text.hasSuffix("*") && text.count > 1)
    }

    /// Strips one layer of `[]`, `()` or `*…*` wrapping, if present.
    private static func strippedWrapper(_ text: String) -> String {
        guard wasWrapped(text), text.count >= 2 else { return text }
        var t = text
        t.removeFirst()
        t.removeLast()
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
