import Foundation

/// One parsed line of a `live.md`/`final.md` transcript. The utterance
/// shape (`**[HH:MM:SS] Speaker:** text`) is a public file-format
/// contract (`.erratum/product/architecture/transcript-format.md`), so this parser is deliberately
/// conservative: anything that doesn't match a known shape exactly is
/// passed through as `.plain` and rendered verbatim.
public enum TranscriptLine: Equatable, Sendable {
    case marker
    case header(String)
    case utterance(timestamp: String, speaker: String, text: String)
    case plain(String)
    case blank

    public static func parse(_ line: String) -> TranscriptLine {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        if line.hasPrefix("<!-- pulsartrace:") { return .marker }
        if line.hasPrefix("## ") {
            return .header(String(line.dropFirst(3)))
        }
        // `**[HH:MM:SS] <speaker>:** <text>` — the speaker group's greedy
        // `.+` matches up to the LAST `:**` (it grabs everything first,
        // then backtracks only as far as needed), so names containing
        // colons survive. Local literal: `Regex` is not Sendable, so a
        // `static let` would violate Swift 6 strict concurrency — revisit
        // if a future stdlib makes Regex Sendable (the runtime caches the
        // compiled program, so per-call construction costs ~nothing).
        let utteranceRegex = /^\*\*\[(\d{2}:\d{2}:\d{2})\] (.+):\*\* (.*)$/
        if let match = line.wholeMatch(of: utteranceRegex) {
            return .utterance(
                timestamp: String(match.1),
                speaker: String(match.2),
                text: String(match.3))
        }
        return .plain(line)
    }
}
