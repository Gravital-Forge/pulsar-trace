import Foundation
import PulsarTraceEngine

/// One past recording, surfaced in the menubar recordings list (R31).
///
/// Decoded from a recording folder's `metadata.json` sidecar — the
/// machine-readable summary a refine pass writes — when present. A folder
/// with no `metadata.json` but with a `live.md` (or `audio-system.wav`) is a
/// just-recorded or failed-to-refine recording: it still surfaces as an entry
/// with `isRefined == false` so the user can refine it from the list (FIX 3).
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
    /// Prefers the `metadata.json` sidecar (a refined recording). When that is
    /// absent, falls back to surfacing an *unrefined* recording — a folder
    /// holding a `live.md` or an `audio-system.wav` but no `metadata.json`
    /// (just recorded, or a refine that failed): see `decodeUnrefined`.
    /// Returns `nil` only for a folder that is neither — an empty or garbage
    /// folder the scanner skips.
    static func decode(folderURL: URL) -> RecordingEntry? {
        let fm = FileManager.default
        let metadataURL = folderURL.appendingPathComponent(
            RecordingFolder.FileName.metadata)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(
                RefinementMetadata.self, from: data)
        else {
            // No usable metadata.json — try the unrefined fallback.
            return decodeUnrefined(folderURL: folderURL)
        }

        let finalURL = folderURL.appendingPathComponent(
            RecordingFolder.FileName.final)
        let isRefined = fm.fileExists(atPath: finalURL.path)

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

    /// Surface a recording folder that has **no** `metadata.json` — a
    /// just-recorded or failed-to-refine recording (FIX 3).
    ///
    /// Such a folder holds only `live.md` + `audio-*.wav`; `metadata.json` is
    /// written *by* the refine pass. Fields are derived best-effort: the id
    /// from the folder name (the same deterministic derivation a later refine
    /// will use, so the entry's id is stable across the refine), the start
    /// date from the `yyyy-MM-dd-HHmmss` folder name, duration unknown (`0`),
    /// speakers empty. Returns `nil` if the folder has neither a `live.md` nor
    /// an `audio-system.wav` — then it is not a recording at all.
    static func decodeUnrefined(folderURL: URL) -> RecordingEntry? {
        let fm = FileManager.default
        let liveURL = folderURL.appendingPathComponent(
            RecordingFolder.FileName.live)
        let audioURL = folderURL.appendingPathComponent(
            RecordingFolder.FileName.audioSystem)
        guard fm.fileExists(atPath: liveURL.path)
            || fm.fileExists(atPath: audioURL.path) else { return nil }

        let name = folderURL.lastPathComponent
        return RecordingEntry(
            id: RecordingFolder.recordingId(forName: name),
            recordingStart: Self.folderNameDate(name)
                ?? Date(timeIntervalSince1970: 0),
            folderURL: folderURL,
            durationSeconds: 0,
            speakers: [],
            isRefined: false)
    }

    /// Parse a `yyyy-MM-dd-HHmmss` recording-folder basename into a `Date`.
    /// A name not in that shape yields `nil`.
    private static func folderNameDate(_ name: String) -> Date? {
        Self.folderNameFormatter.date(from: name)
    }

    /// `yyyy-MM-dd-HHmmss` parser, matching `RecordingViewModel`'s folder
    /// naming. `DateFormatter` is `Sendable`.
    private static let folderNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

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
