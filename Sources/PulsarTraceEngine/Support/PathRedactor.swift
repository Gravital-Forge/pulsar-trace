import Foundation

/// Single-source path redaction for human-visible log lines and UI strings.
///
/// PulsarTrace's PRD has a hard invariant (Hard Invariant #7): no full
/// user-chosen filesystem paths in `~/Library/Logs/PulsarTrace/` or in any
/// UI surface. When Foundation errors are interpolated via `\(error)`, their
/// `description` frequently embeds `NSFilePathErrorKey` (a full path); this
/// utility strips those patterns before the string crosses a logging or UI
/// boundary.
///
/// Two entry points:
///   - `redactHome(_:)` — replaces only `NSHomeDirectory()` with `~`. Use at
///     log/UI sites where no recording-folder URL is in scope.
///   - `redact(_:folder:)` — also replaces `folder.path` with `<folder>`,
///     stripping more aggressively when a known recording-folder URL is
///     available. Used by `ResumableRefiner` for the
///     `refine-progress.json` `lastError` field.
public enum PathRedactor {

    /// Replace any occurrence of the user's home directory with `~` so a
    /// rendered error string does not leak `/Users/<name>/…` into a log or
    /// UI surface.
    public static func redactHome(_ s: String) -> String {
        s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Replace `folder.path` with `<folder>` and `NSHomeDirectory()` with
    /// `~`, in that order. Order matters: `folder.path` is the longer,
    /// more-specific prefix on a typical layout, so stripping it first
    /// produces a cleaner `<folder>/…` substring; the second pass then
    /// catches any home-directory references outside the folder. The second
    /// replacement never double-rewrites because `<folder>` does not contain
    /// `/Users/…`.
    public static func redact(_ s: String, folder: URL) -> String {
        var out = s.replacingOccurrences(of: folder.path, with: "<folder>")
        out = out.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return out
    }
}
