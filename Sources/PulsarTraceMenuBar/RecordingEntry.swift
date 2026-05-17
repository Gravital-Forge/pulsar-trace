import Foundation
import PulsarTraceEngine

/// One past recording, surfaced in the menubar recordings list (R31).
///
/// Decoded from a recording folder's `metadata.json` sidecar — the
/// machine-readable summary a refine pass writes. A folder without a
/// `metadata.json` is not a refined recording and produces no entry.
public struct RecordingEntry: Identifiable, Sendable, Equatable {

    /// The recording id (`rec_<short>`), from `metadata.json`. Stable across
    /// re-refines — usable as the `Identifiable` id.
    public let id: String
    /// Wall-clock the recording started.
    public let recordingStart: Date
    /// The recording folder on disk.
    public let folderURL: URL
    /// Audio duration in seconds (the longer stream).
    public let durationSeconds: Double
    /// Distinct speaker labels in the final transcript.
    public let speakers: [String]
    /// Whether a `final.md` is present (the recording has been refined).
    public let isRefined: Bool

    public init(
        id: String,
        recordingStart: Date,
        folderURL: URL,
        durationSeconds: Double,
        speakers: [String],
        isRefined: Bool
    ) {
        self.id = id
        self.recordingStart = recordingStart
        self.folderURL = folderURL
        self.durationSeconds = durationSeconds
        self.speakers = speakers
        self.isRefined = isRefined
    }

    /// The display name shown in the list — the recording folder's basename.
    public var displayName: String { folderURL.lastPathComponent }

    /// Decode a `RecordingEntry` from a recording folder.
    ///
    /// Returns `nil` when the folder has no `metadata.json` or it cannot be
    /// decoded — the scanner skips such folders rather than failing the scan.
    static func decode(folderURL: URL) -> RecordingEntry? {
        let metadataURL = folderURL.appendingPathComponent(
            RecordingFolder.FileName.metadata)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(
                RefinementMetadata.self, from: data)
        else { return nil }

        let finalURL = folderURL.appendingPathComponent(
            RecordingFolder.FileName.final)
        let isRefined = FileManager.default.fileExists(atPath: finalURL.path)

        let start = Self.iso8601.date(from: metadata.recordingStart)
            ?? Date(timeIntervalSince1970: 0)

        return RecordingEntry(
            id: metadata.recordingId,
            recordingStart: start,
            folderURL: folderURL,
            durationSeconds: metadata.durationSeconds,
            speakers: metadata.speakers.map(\.label),
            isRefined: isRefined)
    }

    /// ISO-8601 UTC parser matching `Timestamps.event` output.
    ///
    /// `ISO8601DateFormatter` is not `Sendable`, but this instance is fully
    /// configured at init and afterwards only read via `date(from:)` — Apple
    /// documents that as thread-safe on a no-longer-mutated formatter (same
    /// hand-checked invariant as `Timestamps`' cached formatters).
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
