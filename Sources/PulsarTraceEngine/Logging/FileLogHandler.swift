import Foundation
import Logging

/// A `swift-log` `LogHandler` that writes the PulsarTrace operational log line
/// format (§11) to a daily-rotated file via `LogRotator`.
///
/// Line format (§11 "File layout"):
///
///     2026-04-30T14:30:05.123Z  notice  capture           message text
///
/// Columns: ISO-8601 UTC timestamp · level · subsystem · message. The
/// `swift-log` `label` is used as the subsystem column.
public struct FileLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level

    private let label: String
    private let rotator: LogRotator
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - label: the subsystem name (`swift-log` label).
    ///   - rotator: the shared rotating-file owner.
    ///   - level: the minimum level this handler emits (default `notice`, PT-R58).
    ///   - clock: injectable wall clock for deterministic tests.
    public init(
        label: String,
        rotator: LogRotator,
        level: Logger.Level = .notice,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.label = label
        self.rotator = rotator
        self.logLevel = level
        self.clock = clock
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: Logging.LogEvent) {
        let line = Self.format(
            timestamp: clock(),
            level: event.level,
            subsystem: label,
            message: event.message.description
        )
        // Synchronous + serialised on the rotator's queue: when this returns
        // the line is durably written. No fire-and-forget `Task`, so a line is
        // never lost if the process exits immediately after logging.
        rotator.append(line)
    }

    /// Render one log line in the documented column format.
    public static func format(
        timestamp: Date,
        level: Logger.Level,
        subsystem: String,
        message: String
    ) -> String {
        let ts = Timestamps.logLine(timestamp)
        let lvl = level.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
        let sub = subsystem.padding(toLength: 18, withPad: " ", startingAt: 0)
        // Collapse newlines so one log event is always one physical line.
        let flat = message.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(ts)  \(lvl) \(sub) \(flat)"
    }
}
