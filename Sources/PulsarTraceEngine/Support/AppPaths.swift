import Foundation

/// Resolves the on-disk locations PulsarTrace uses.
///
/// All locations derive from `home` (the user's home directory by default),
/// except the model cache when `modelsOverride` is set. Tests inject a
/// temporary `home` so they never touch the real `~/Library`.
public struct AppPaths: Sendable {
    /// Base directory; the real app uses the user's home directory.
    public let home: URL

    /// Optional model-store override (`PULSARTRACE_MODELS_DIR`, PT-R126) so
    /// an isolated E2E home can still share the already-downloaded models.
    public let modelsOverride: URL?

    public init(home: URL, modelsOverride: URL? = nil) {
        self.home = home
        self.modelsOverride = modelsOverride
    }

    /// The real application paths — the user's home unless the E2E override
    /// re-roots them (PT-R126).
    public static var standard: AppPaths { standard(overrides: .current) }

    /// Overrides-aware resolver; tests inject a synthetic environment.
    // PT-R126
    public static func standard(overrides: EnvironmentOverrides) -> AppPaths {
        AppPaths(
            home: overrides.home
                ?? FileManager.default.homeDirectoryForCurrentUser,
            modelsOverride: overrides.modelsDirectory)
    }

    /// Operational log directory: `~/Library/Logs/PulsarTrace/` (PT-R57).
    public var logDirectory: URL {
        home.appendingPathComponent("Library/Logs/PulsarTrace", isDirectory: true)
    }

    /// Application Support root: `~/Library/Application Support/PulsarTrace/`.
    public var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/PulsarTrace", isDirectory: true)
    }

    /// Model cache root: `~/Library/Caches/PulsarTrace/models/` (PT-P1-D10),
    /// or the `PULSARTRACE_MODELS_DIR` override verbatim (PT-R126). The CoreML
    /// bundles (Parakeet `parakeet-tdt-0.6b-v3-coreml/`, WhisperKit
    /// `whisperkit/`) live in SDK-managed subdirectories beneath it (PT-P5-D2).
    public var modelsCacheDirectory: URL {
        modelsOverride ?? home.appendingPathComponent(
            "Library/Caches/PulsarTrace/models", isDirectory: true)
    }

    /// Events log directory: `…/PulsarTrace/events/` (PT-R78).
    public var eventsDirectory: URL {
        applicationSupport.appendingPathComponent("events", isDirectory: true)
    }

    /// Persistent speaker-library SQLite database:
    /// `…/PulsarTrace/speakers.sqlite` (PT-R28).
    public var speakersDatabaseURL: URL {
        applicationSupport.appendingPathComponent("speakers.sqlite", isDirectory: false)
    }

    /// The owner-only file holding the MCP server's bearer token (PT-R116).
    public var mcpTokenURL: URL {
        applicationSupport.appendingPathComponent("mcp-token", isDirectory: false)
    }

    /// Directory for per-session Unix domain sockets. Lives under
    /// `$TMPDIR/PulsarTrace/` rather than `applicationSupport` because
    /// `sockaddr_un.sun_path` is hard-capped at 104 bytes on Darwin
    /// (incl. NUL) — and `~/Library/Application Support/PulsarTrace/`
    /// alone consumes ~63 bytes for a 7-char username and grows with
    /// username length. `$TMPDIR` resolves to `/var/folders/<2>/<28>/T/`
    /// on macOS (~47 bytes, constant regardless of username), leaving
    /// ~50 bytes of headroom for the longest filenames the code uses
    /// (capture's `<recordingId>-system.sock` ≈ 33 bytes).
    ///
    /// `home` is left in place because everything else under
    /// `applicationSupport` (events, speakers DB, etc.)
    /// is persistent state that genuinely belongs in Application Support.
    /// Only the sockets need short paths.
    public var socketDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PulsarTrace", isDirectory: true)
    }

    /// The system-audio capture socket for one recording session.
    /// The `recordingId` keeps concurrent sessions from colliding.
    public func systemSocketURL(recordingId: String) -> URL {
        socketDirectory.appendingPathComponent(
            "\(recordingId)-system.sock", isDirectory: false)
    }

    /// The microphone capture socket for one recording session.
    public func micSocketURL(recordingId: String) -> URL {
        socketDirectory.appendingPathComponent(
            "\(recordingId)-mic.sock", isDirectory: false)
    }
}

/// ISO-8601 / UTC formatting used by both the operational log and events log.
///
/// The formatters are allocated once and cached as statics: `logLine`/`event`
/// are hot paths (one call per log line / per event), and
/// `ISO8601DateFormatter`/`DateFormatter` are expensive to construct. The
/// formatters are immutable after construction and only read here, so sharing
/// them across threads is safe.
public enum Timestamps {
    /// `2026-04-30T14:30:05.123Z` — millisecond precision, used in log lines.
    public static func logLine(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    /// `2026-04-30T14:30:05Z` — second precision, used in event envelopes.
    public static func event(_ date: Date) -> String {
        secondFormatter.string(from: date)
    }

    /// `2026-04-30` in UTC — used for daily-rotated file names.
    public static func dayStamp(_ date: Date) -> String {
        dayStampFormatter.string(from: date)
    }

    // `ISO8601DateFormatter`/`DateFormatter` are not `Sendable`, but each is
    // fully configured at init and afterwards only read via `string(from:)`,
    // which Apple documents as thread-safe on a formatter that is no longer
    // being mutated. `nonisolated(unsafe)` reflects that hand-checked
    // invariant — the alternative (a new formatter per call) is the hot-path
    // allocation S2 is removing.

    /// Cached ISO-8601 formatter with fractional seconds (`fractional: true`).
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter =
        makeFormatter(fractional: true)

    /// Cached ISO-8601 formatter without fractional seconds (`fractional: false`).
    private nonisolated(unsafe) static let secondFormatter: ISO8601DateFormatter =
        makeFormatter(fractional: false)

    /// Cached day-stamp formatter (`DateFormatter` is `Sendable`).
    private static let dayStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }
}
