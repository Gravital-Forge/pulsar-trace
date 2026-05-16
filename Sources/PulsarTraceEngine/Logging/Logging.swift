import Foundation
import Logging

/// Bootstraps the PulsarTrace operational logging system (§11).
///
/// Two `swift-log` backends are wired in parallel for every logger:
/// 1. `FileLogHandler` — the daily-rotated text file at
///    `~/Library/Logs/PulsarTrace/YYYY-MM-DD.log`.
/// 2. `OSLogHandler` — the `os.Logger` bridge for Console.app / `log show`.
///
/// Call `LogSystem.bootstrap` exactly once at process start. The default
/// visible level is `notice` (R58); `info`/`debug` are off unless explicitly
/// raised.
public enum LogSystem {
    /// The shared rotator, retained so `flush()` can run on shutdown.
    public private(set) static nonisolated(unsafe) var rotator: LogRotator?

    /// `swift-log`'s global factory may be set exactly once per process. This
    /// flag makes `bootstrap` idempotent so repeated `AppLifecycle.start` calls
    /// — e.g. across in-process tests — do not trap.
    private static nonisolated(unsafe) var didBootstrapFactory = false
    private static let bootstrapLock = NSLock()

    /// Wire both backends into `swift-log`'s global factory.
    ///
    /// - Parameters:
    ///   - paths: where the log directory lives (injectable for tests).
    ///   - level: default visible level (R58 default: `.notice`).
    ///   - retentionDays: file retention window (R57: 7).
    ///   - clock: injectable wall clock for deterministic rotation tests.
    @discardableResult
    public static func bootstrap(
        paths: AppPaths = .standard,
        level: Logger.Level = .notice,
        retentionDays: Int = 7,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) async -> LogRotator {
        let rotator = LogRotator(
            directory: paths.logDirectory,
            retentionDays: retentionDays,
            clock: clock
        )
        rotator.bootstrap()

        // Set the global factory at most once: `LoggingSystem.bootstrap` traps
        // on a second call, so repeated `AppLifecycle.start` (e.g. across
        // in-process tests) must be a no-op for the factory. The shared
        // `rotator` is published under the same lock so the assignment is not
        // visible before — or racing — the factory-init decision.
        let firstTime = bootstrapLock.withLock {
            self.rotator = rotator
            let first = !didBootstrapFactory
            didBootstrapFactory = true
            return first
        }

        if firstTime {
            LoggingSystem.bootstrap { label in
                MultiplexLogHandler([
                    FileLogHandler(label: label, rotator: rotator, level: level, clock: clock),
                    OSLogHandler(label: label, level: level),
                ])
            }
        }
        return rotator
    }

    /// Flush the file backend; call on app shutdown. `flush()` is a synchronous
    /// barrier on the rotator's serial queue, so every queued line is durably
    /// written before this returns.
    public static func shutdown() async {
        let rotator = bootstrapLock.withLock { self.rotator }
        rotator?.flush()
    }
}

/// Standard subsystem labels used as the log line's subsystem column. Keeping
/// them centralized makes the content-leak test and `log` predicates reliable.
public enum LogSubsystem {
    public static let app = "app"
    public static let engine = "engine"
    public static let capture = "capture"
    public static let refine = "refine"
    public static let ipc = "ipc"
    public static let events = "events"
}
