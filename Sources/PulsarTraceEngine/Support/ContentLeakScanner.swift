import Foundation

/// Scans a log (operational or events) for content that must never appear
/// (PT-R59, PT-R84, §11 "What is NEVER logged").
///
/// This is the shared scaffolding behind the privacy assertions: a test
/// produces a real log, then asserts `scan` finds nothing. Forbidden inputs are
/// the kinds of things that would leak — transcript text, audio data
/// representations, the user's speaker names (operational log only), and full
/// home-directory paths.
public enum ContentLeakScanner {

    /// A single leak finding: the forbidden needle and where it was seen.
    public struct Finding: Equatable, CustomStringConvertible {
        public let needle: String
        public let lineNumber: Int
        public let line: String

        public var description: String {
            "line \(lineNumber): forbidden content '\(needle)'"
        }
    }

    /// Scan `logText` for any literal `forbidden` substring, plus a built-in
    /// check for absolute paths under `/Users/<name>/…` deeper than the home
    /// directory itself (full user paths must never be logged — basenames only).
    ///
    /// - Parameters:
    ///   - logText: the full text of a produced log.
    ///   - forbidden: literal needles that must not appear (transcript text,
    ///     speaker names, etc.). Case-sensitive.
    ///   - checkUserPaths: also flag full `/Users/<name>/…` paths (default true).
    public static func scan(
        logText: String,
        forbidden: [String],
        checkUserPaths: Bool = true
    ) -> [Finding] {
        var findings: [Finding] = []
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = String(raw)
            for needle in forbidden where !needle.isEmpty && line.contains(needle) {
                findings.append(Finding(needle: needle, lineNumber: index + 1, line: line))
            }
            if checkUserPaths, let path = userPath(in: line) {
                findings.append(Finding(needle: path, lineNumber: index + 1, line: line))
            }
        }
        return findings
    }

    /// Find a full user path (`/Users/<name>/<more>`) in a line, if any.
    ///
    /// `/Users/alice` alone is allowed (it has no content); `/Users/alice/…`
    /// with a further path component is a full user path and a leak.
    static func userPath(in line: String) -> String? {
        guard let range = line.range(
            of: #"/Users/[^/\s]+/[^\s'"]+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range])
    }
}
