import Foundation

/// Owns the rotating operational-log file (§11 "Rotation").
///
/// Responsibilities:
/// - Open today's `YYYY-MM-DD.log` in append mode.
/// - On launch and whenever the day rolls over, prune files older than the
///   retention window.
/// - Append formatted log lines; flush is the caller's concern (the file
///   handle writes are unbuffered `write(2)` calls here, so each line is
///   durable enough for the volume target in §11).
///
/// All mutating work runs on a single serial `DispatchQueue` so concurrent
/// loggers cannot interleave partial lines, and so a midnight rotation cannot
/// race a write. The queue — rather than an
/// actor — is used deliberately: `append` is called synchronously from
/// `FileLogHandler.log`, which is not `async`, and `flush()` is a synchronous
/// barrier that reliably drains every queued line on `shutdown()`. A fire-and-
/// forget `Task` would otherwise be lost if the process exits before it runs.
public final class LogRotator: @unchecked Sendable {
    private let directory: URL
    private let retentionDays: Int
    private let clock: @Sendable () -> Date
    /// Serialises all file mutation and rotation. `append`/`bootstrap` are
    /// `sync`-dispatched so callers observe a stable ordering and `flush()`
    /// drains everything queued before it.
    private let queue = DispatchQueue(label: "com.gravitalforge.pulsartrace.logrotator")
    private var handle: FileHandle?
    private var currentDay: String = ""

    /// - Parameters:
    ///   - directory: the log directory (`~/Library/Logs/PulsarTrace`).
    ///   - retentionDays: delete files older than this many days (R57: 7).
    ///   - clock: injectable wall clock for deterministic rotation tests.
    public init(
        directory: URL,
        retentionDays: Int = 7,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.clock = clock
    }

    /// Open today's file and prune expired files. Safe to call repeatedly.
    public func bootstrap() {
        queue.sync {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()
            prune()
        }
    }

    /// Append one already-formatted log line (no trailing newline expected).
    ///
    /// Synchronous and serialised: when this returns, the line is durably
    /// written. `FileLogHandler.log` therefore needs no fire-and-forget task,
    /// so no line is lost on a fast process exit.
    public func append(_ line: String) {
        queue.sync {
            rotateIfNeeded()
            guard let handle else { return }
            if let data = (line + "\n").data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Force an fsync — called on app shutdown (§11 "Implementation"). The
    /// `sync` dispatch also acts as a barrier: every previously-queued
    /// `append` has completed before the fsync runs.
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    /// Current log file URL, for tests.
    public func currentFileURL() -> URL {
        queue.sync {
            directory.appendingPathComponent("\(currentDay).log")
        }
    }

    // MARK: - Internals

    /// Open a new file if the local day changed since the last write.
    /// Must run on `queue`.
    private func rotateIfNeeded() {
        let today = Timestamps.dayStamp(clock())
        guard today != currentDay else {
            if handle == nil { openFile(for: today) }
            return
        }
        // Day rolled over (or first open): close, reopen, prune.
        if handle != nil {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
        openFile(for: today)
        prune()
    }

    /// Must run on `queue`.
    private func openFile(for day: String) {
        currentDay = day
        let url = directory.appendingPathComponent("\(day).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Delete `*.log` files whose date stamp is older than the retention
    /// window. Must run on `queue`.
    private func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let cutoff = clock().addingTimeInterval(-Double(retentionDays) * 86_400)
        let cutoffDay = Timestamps.dayStamp(cutoff)
        for entry in entries where entry.pathExtension == "log" {
            let stem = entry.deletingPathExtension().lastPathComponent
            // File names are lexicographically comparable date stamps.
            if stem.count == 10, stem < cutoffDay {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
