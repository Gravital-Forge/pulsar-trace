import Foundation
import PulsarTraceEngine

/// Reads/writes the UI-owned `title.txt` sidecar inside a recording folder
/// (spec §4.1). The engine never reads this file and `metadata.json` stays
/// refine-owned, so a re-refine can never clobber a user-assigned title. The
/// folder basename — which the recording id derives from — is never renamed.
public enum RecordingTitleStore {

    /// Single-line normalization: newlines collapse to spaces, surrounding
    /// whitespace trimmed; `nil` when nothing printable remains.
    public static func normalized(_ raw: String) -> String? {
        let flattened = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The custom title stored in `folderURL`, or `nil` (absent or blank).
    public static func read(folderURL: URL) -> String? {
        let url = folderURL.appendingPathComponent(RecordingFolder.FileName.title)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return normalized(raw)
    }

    /// Persist `rawTitle` atomically; a title that normalizes to nothing
    /// removes the sidecar so the date-based default title returns.
    public static func write(_ rawTitle: String, folderURL: URL) throws {
        let url = folderURL.appendingPathComponent(RecordingFolder.FileName.title)
        guard let title = normalized(rawTitle) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try Data((title + "\n").utf8).write(to: url, options: .atomic)
    }
}
