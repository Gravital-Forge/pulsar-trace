import Foundation

/// "Copy copies what you see" (§5): the styled renderer's text content as a
/// plain string — `[HH:MM:SS] Speaker  text` per utterance, headers verbatim,
/// comment markers and blank lines dropped. The raw Markdown file remains one
/// Reveal-in-Finder away for anyone who wants the source form.
public enum TranscriptPlainText {
    public static func rendered(from lines: [String]) -> String {
        var out: [String] = []
        for raw in lines {
            switch TranscriptLine.parse(raw) {
            case .utterance(let ts, let speaker, let text):
                out.append("[\(ts)] \(speaker)  \(text)")
            case .header(let title):
                out.append(title)
            case .plain(let s):
                out.append(s)
            case .marker, .blank:
                continue
            }
        }
        return out.joined(separator: "\n")
    }
}
