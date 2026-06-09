import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Append-only JSONL writer for the events log (§8.13, R78–R86).
///
/// The events log is a public API surface: a machine-readable stream that LLM
/// agents and external tools consume. Every line is a self-contained JSON
/// object carrying the common envelope (`ts`, `type`, `id`, `version`) plus the
/// event's type-specific payload.
///
/// Files are daily-rotated (`events/YYYY-MM-DD.jsonl`) with a 30-day retention
/// window; expired files are pruned on launch and on each day rollover. A
/// single actor serializes appends so concurrent emitters cannot interleave a
/// partial line and a rotation cannot race a write.
public actor EventWriter {
    /// Raised when an event cannot be durably persisted. The events log is a
    /// public API surface, so a dropped write must surface as an error rather
    /// than a silently-successful `append`.
    public enum WriteError: Error, CustomStringConvertible {
        /// No open file handle — the events file could not be opened.
        case noOpenFile
        /// The encoded line could not be converted to UTF-8 bytes.
        case encodingFailed
        /// `flock(LOCK_EX)` returned non-zero; the raw errno is embedded.
        case lockFailed(errno: Int32)

        public var description: String {
            switch self {
            case .noOpenFile: return "events file is not open; event not persisted"
            case .encodingFailed: return "event line could not be UTF-8 encoded"
            case .lockFailed(let e): return "events file flock failed: errno \(e)"
            }
        }
    }

    private let directory: URL
    private let retentionDays: Int
    private let clock: @Sendable () -> Date
    private let ulidFactory: @Sendable (Date) -> ULID
    private var handle: FileHandle?
    private var currentDay: String = ""

    /// - Parameters:
    ///   - directory: events directory (`…/PulsarTrace/events`).
    ///   - retentionDays: retention window (R79: 30).
    ///   - clock: injectable wall clock for deterministic rotation tests.
    ///   - ulidFactory: injectable ULID source so event IDs are deterministic
    ///     in tests (the determinism rule: all RNG seeded).
    public init(
        directory: URL,
        retentionDays: Int = 30,
        clock: @escaping @Sendable () -> Date = { Date() },
        ulidFactory: @escaping @Sendable (Date) -> ULID = { ULID.generate(timestamp: $0) }
    ) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.clock = clock
        self.ulidFactory = ulidFactory
    }

    /// Create the events directory, open today's file, prune expired files.
    public func bootstrap() {
        try? SecureFiles.ensurePrivateDirectory(at: directory)
        rotateIfNeeded()
        prune()
    }

    /// Append one event: envelope + payload, as a single JSON line.
    ///
    /// - Returns: the ULID assigned to the event (`evt_<ulid>` form).
    @discardableResult
    public func append<P: EventPayload>(_ payload: P) throws -> String {
        rotateIfNeeded()
        let now = clock()
        let id = "evt_\(ulidFactory(now).value)"
        let envelope = Envelope(
            ts: Timestamps.event(now),
            type: P.eventType,
            id: id,
            version: P.schemaVersion
        )
        let line = try Self.encodeLine(envelope: envelope, payload: payload)
        guard let handle else { throw WriteError.noOpenFile }
        guard let data = (line + "\n").data(using: .utf8) else {
            throw WriteError.encodingFailed
        }

        // Cross-process exclusion. Both `pulsartrace-mac` and
        // `pulsartrace-capture` append to the same daily file; the actor only
        // serialises within one process. Without flock, the two processes
        // can interleave bytes mid-line — observed in
        // events/2026-05-20.jsonl where a `recording_paused` was clobbered by
        // an `app_stopped`. `flock(LOCK_EX)` is advisory: it only guards
        // against other callers that also `flock` the file, which every
        // EventWriter does. Released in `defer` so a thrown `write` still
        // unlocks.
        let fd = handle.fileDescriptor
        guard flock(fd, LOCK_EX) == 0 else {
            throw WriteError.lockFailed(errno: errno)
        }
        defer { _ = flock(fd, LOCK_UN) }

        // Re-anchor to end-of-file every write. Two processes share this
        // file: A's writes advance A's handle position but NOT B's, so
        // without re-seeking each writer would clobber bytes added by the
        // other since this writer's last write. flock guarantees no other
        // writer holds the lock right now, so the seek-then-write pair is
        // atomic w.r.t. other EventWriters.
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        return id
    }

    /// fsync the events file — call on app shutdown.
    public func flush() {
        try? handle?.synchronize()
    }

    /// Current events file URL, for tests.
    public func currentFileURL() -> URL {
        directory.appendingPathComponent("\(currentDay).jsonl")
    }

    // MARK: - Encoding

    /// The common envelope written on every event (R80).
    struct Envelope: Encodable {
        let ts: String
        let type: String
        let id: String
        let version: Int
    }

    /// Merge envelope + payload into one flat JSON object, one line.
    ///
    /// Both are encoded separately then merged so payloads stay simple structs
    /// without having to restate the envelope fields.
    static func encodeLine<P: EventPayload>(envelope: Envelope, payload: P) throws -> String {
        let encoder = JSONEncoder()
        // Stable key order makes the JSONL snapshot-testable.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let envData = try encoder.encode(envelope)
        let payloadData = try encoder.encode(payload)

        var merged = try JSONSerialization.jsonObject(with: envData) as? [String: Any] ?? [:]
        let payloadObj = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] ?? [:]
        for (k, v) in payloadObj { merged[k] = v }

        let lineData = try JSONSerialization.data(
            withJSONObject: merged, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: lineData, as: UTF8.self)
    }

    // MARK: - Rotation

    private func rotateIfNeeded() {
        let today = Timestamps.dayStamp(clock())
        guard today != currentDay else {
            if handle == nil { openFile(for: today) }
            return
        }
        if handle != nil {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
        openFile(for: today)
        prune()
    }

    private func openFile(for day: String) {
        currentDay = day
        let url = directory.appendingPathComponent("\(day).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            SecureFiles.createPrivateFile(atPath: url.path)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func prune() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let cutoff = clock().addingTimeInterval(-Double(retentionDays) * 86_400)
        let cutoffDay = Timestamps.dayStamp(cutoff)
        for entry in entries where entry.pathExtension == "jsonl" {
            let stem = entry.deletingPathExtension().lastPathComponent
            if stem.count == 10, stem < cutoffDay {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
