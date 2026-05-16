import Foundation
import Logging
import os

/// A `swift-log` `LogHandler` that bridges to `os.Logger` under the
/// `app.pulsartrace` subsystem (R61, §11).
///
/// This is the second backend wired in parallel with `FileLogHandler`: it makes
/// PulsarTrace events visible to `log show --predicate 'subsystem ==
/// "app.pulsartrace"'` and Console.app, the native debugging path for users
/// comfortable with Mac tools.
public struct OSLogHandler: LogHandler {
    /// The subsystem string Console.app / `log` users predicate on.
    public static let subsystem = "app.pulsartrace"

    public var metadata: Logging.Logger.Metadata = [:]
    public var logLevel: Logging.Logger.Level

    private let osLogger: os.Logger

    /// - Parameters:
    ///   - label: the `swift-log` label, used as the `os.Logger` category.
    ///   - level: the minimum level this handler emits.
    public init(label: String, level: Logging.Logger.Level = .notice) {
        self.osLogger = os.Logger(subsystem: Self.subsystem, category: label)
        self.logLevel = level
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: Logging.LogEvent) {
        osLogger.log(
            level: Self.osType(for: event.level),
            "\(event.message.description, privacy: .public)")
    }

    /// Map a `swift-log` level onto the closest `OSLogType`.
    private static func osType(for level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: return .debug
        case .info, .notice: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}
