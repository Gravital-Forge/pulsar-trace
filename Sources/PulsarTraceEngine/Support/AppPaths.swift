import Foundation

/// Resolves the on-disk locations PulsarTrace uses.
///
/// All locations are derived from a `root` (the user's home directory by
/// default). Tests inject a temporary root so they never touch the real
/// `~/Library`.
public struct AppPaths: Sendable {
    /// Base directory; the real app uses the user's home directory.
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// The real application paths, rooted at the current user's home.
    public static var standard: AppPaths {
        AppPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Operational log directory: `~/Library/Logs/PulsarTrace/` (R57).
    public var logDirectory: URL {
        home.appendingPathComponent("Library/Logs/PulsarTrace", isDirectory: true)
    }

    /// Application Support root: `~/Library/Application Support/PulsarTrace/`.
    public var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/PulsarTrace", isDirectory: true)
    }

    /// Events log directory: `…/PulsarTrace/events/` (R78).
    public var eventsDirectory: URL {
        applicationSupport.appendingPathComponent("events", isDirectory: true)
    }

    /// Persistent speaker-library SQLite database:
    /// `…/PulsarTrace/speakers.sqlite` (R28).
    public var speakersDatabaseURL: URL {
        applicationSupport.appendingPathComponent("speakers.sqlite", isDirectory: false)
    }

    /// Directory for per-session capture sockets: `…/PulsarTrace/sockets/`.
    /// `pulsartrace-capture` binds its Unix domain sockets here;
    /// `pulsartrace-engine` connects to them via `SocketSource`.
    public var socketDirectory: URL {
        applicationSupport.appendingPathComponent("sockets", isDirectory: true)
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
