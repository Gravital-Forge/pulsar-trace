import Foundation
import Logging
import PulsarTraceEngine

/// Tails a recording's `live.md` and exposes its lines to the menubar live
/// popover (PT-R40 — the live transcript view).
///
/// READ-ONLY: this type only ever reads `live.md` — it never writes, edits, or
/// truncates it. `live.md` is strictly append-only (Hard Invariant #4), so a
/// poll-based tail is sound: a repeating task sleeps ~0.5 s, reads the bytes
/// that appeared past a tracked file offset, and appends complete lines. This
/// is deterministic and unit-testable (PT-P2-D9 — no reliance on
/// `FileHandle.AsyncBytes` blocking semantics).
@MainActor
@Observable
public final class LiveTranscriptWatcher {

    /// Complete lines read from `live.md` so far, in file order.
    public private(set) var lines: [String] = []

    /// True while the watcher's poll loop is running.
    public private(set) var isActive = false

    /// Poll interval — `live.md` grows slowly (one line per committed
    /// utterance), so a sub-second poll is plenty responsive.
    private let pollInterval: Duration

    /// Byte offset already consumed from the file.
    private var offset: UInt64 = 0
    /// Carry-over of a trailing partial line between polls.
    private var partial = ""
    /// The poll task; cancelled by `stop()`.
    private var pollTask: Task<Void, Never>?
    /// Operational logger — records a `seek` failure rather than swallowing it.
    private let logger = Logger(label: LogSubsystem.menubar)

    /// - Parameter pollInterval: poll cadence (default 0.5 s).
    public init(pollInterval: Duration = .milliseconds(500)) {
        self.pollInterval = pollInterval
    }

    /// Begin tailing `liveMarkdownURL`. Resets prior state; calling `start`
    /// again switches to a new file.
    public func start(liveMarkdownURL: URL) {
        stop()
        lines = []
        offset = 0
        partial = ""
        isActive = true

        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                await self?.poll(url: liveMarkdownURL)
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Stop tailing and cancel the poll loop.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        isActive = false
    }

    /// Read any bytes appended past `offset` and append their complete lines.
    ///
    /// Internal (not private) so a test can drive a single poll deterministically
    /// instead of waiting on the timer.
    func poll(url: URL) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            // A seek failure means the file was truncated or replaced under us
            // — log it (it should not happen: live.md is append-only) rather
            // than swallowing it silently, and skip this poll.
            logger.notice("live.md tail: seek to offset \(offset) failed: \(error)")
            return
        }
        guard let newData = try? handle.readToEnd(), !newData.isEmpty else {
            return
        }
        offset += UInt64(newData.count)

        let chunk = partial + (String(data: newData, encoding: .utf8) ?? "")
        // Split keeping empty subsequences so blank transcript lines are kept;
        // the final element is a (possibly empty) partial line carried over.
        var pieces = chunk.components(separatedBy: "\n")
        partial = pieces.removeLast()
        lines.append(contentsOf: pieces)
    }
}
