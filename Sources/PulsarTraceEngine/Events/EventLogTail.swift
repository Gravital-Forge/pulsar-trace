import Foundation

/// Reads the events log for `pulsartrace events tail` (PT-R86).
///
/// The events log is a public API surface (`.erratum/product/architecture/events-log.md`): one
/// daily-rotated JSONL file per local day. This type resolves *today's* file
/// and provides the pure line-parsing/filtering helpers the CLI's follow loop
/// uses. The follow loop itself (poll → read appended bytes → print) lives in
/// the CLI command; everything testable without a timer lives here.
public struct EventLogTail: Sendable {
    /// The events directory (`…/PulsarTrace/events`).
    public let directory: URL
    /// Injectable wall clock — tests pin "today" deterministically.
    private let clock: @Sendable () -> Date

    public init(
        directory: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.clock = clock
    }

    /// The JSONL file the events log is currently appending to —
    /// `events/<today>.jsonl`.
    ///
    /// The day stamp is `Timestamps.dayStamp` (UTC) — the exact same key
    /// `EventWriter.rotateIfNeeded()` uses to name the file, so the tail always
    /// resolves the writer's current append target.
    public func currentFileURL() -> URL {
        directory.appendingPathComponent(
            "\(Timestamps.dayStamp(clock())).jsonl", isDirectory: false)
    }

    /// The `type` field of one JSONL event line, or `nil` when the line is not
    /// a JSON object with a string `type` (blank lines, partial writes).
    public static func eventType(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String
        else { return nil }
        return type
    }

    /// Whether a JSONL line passes the `--type` filter.
    ///
    /// An empty `types` set means "no filter" — every well-formed event line
    /// passes. A non-empty set keeps only lines whose `type` is a member.
    /// A line with no parseable `type` is always dropped: the tail emits
    /// events, not log noise.
    public static func lineMatches(_ line: String, types: Set<String>) -> Bool {
        guard let type = eventType(of: line) else { return false }
        return types.isEmpty || types.contains(type)
    }

    /// Split a raw byte buffer into complete lines plus any trailing partial.
    ///
    /// A poll can read a half-written final line (the writer appends a line at
    /// a time, but a read can still land mid-append). The caller carries the
    /// returned `remainder` into the next poll so a line is only ever printed
    /// once it is whole.
    public static func splitLines(
        _ text: String
    ) -> (lines: [String], remainder: String) {
        guard let lastNewline = text.lastIndex(of: "\n") else {
            return ([], text)
        }
        let complete = text[..<lastNewline]
        let remainder = String(text[text.index(after: lastNewline)...])
        let lines = complete
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return (lines, remainder)
    }
}
