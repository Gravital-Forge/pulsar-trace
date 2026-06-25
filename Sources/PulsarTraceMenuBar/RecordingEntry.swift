import Foundation
import PulsarTraceEngine

/// One speaker on a `RecordingEntry`, mirroring the richer
/// `RefinementMetadata.Speaker` shape so the recordings-list UI can render
/// pills (mic "You" / unknown placeholder / named) without re-decoding
/// `metadata.json`.
///
/// `label` is the transcript-facing string as it appears in `final.md`;
/// `speakerId` is the stable library id (`spk_<ulid>`, PT-R83) when the speaker
/// was reconciled against the library, `nil` for `You` (the mic stream) and
/// for system-stream speakers that were never reconciled (no library, or
/// diarization skipped). `isMicrophone` flags the single "You" speaker — that
/// stream is never diarized (PT-R17).
public struct RecordingSpeaker: Identifiable, Sendable, Equatable, Hashable, Codable {

    /// Display label as it appears in `final.md` (e.g. `Steve`,
    /// `Unknown #1`, `You`, or `Speaker_2` when no library is configured).
    public let label: String
    /// Stable library id (`spk_<ulid>`) when reconciled; `nil` for `You` and
    /// for un-reconciled system-stream speakers.
    public let speakerId: String?
    /// True for the mic-stream "You" speaker; that stream is never diarized.
    public let isMicrophone: Bool

    /// `ForEach` identity. `speakerId` is preferred — it survives a label
    /// rename. When absent (mic, or un-reconciled) we synthesize an id from
    /// the label + mic flag so two unreconciled speakers in the same
    /// recording with *distinct* labels stay distinct. Two unreconciled
    /// speakers sharing the same label collide — `SpeakerPillsView` defends
    /// against that by feeding `ForEach` an enumerated index instead of
    /// trusting this id alone (see comment there).
    public var id: String { speakerId ?? "label:\(label):\(isMicrophone)" }

    public init(label: String, speakerId: String?, isMicrophone: Bool) {
        self.label = label
        self.speakerId = speakerId
        self.isMicrophone = isMicrophone
    }

    /// True when the label matches `Unknown #<ASCII digits>` — the
    /// placeholder shape `SpeakerReconciler.nextUnknownName()` emits.
    /// Drives the "unknown" pill tint in the UI; does NOT imply
    /// `speakerId == nil` (a reconciled speaker can still carry an
    /// `Unknown #N` name until the user renames it).
    ///
    /// Restricted to ASCII `0...9` on purpose — Unicode digit lookalikes
    /// (fullwidth `１`, Arabic-Indic `٢`) are NOT placeholders we emit
    /// and should keep the standard "named" tint.
    public var isUnknownPlaceholder: Bool {
        let prefix = "Unknown #"
        guard label.hasPrefix(prefix) else { return false }
        let suffix = label.dropFirst(prefix.count)
        guard !suffix.isEmpty else { return false }
        return suffix.allSatisfy { ("0"..."9").contains($0) }
    }
}

/// One past recording, surfaced in the menubar recordings list (PT-R31).
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
    /// Distinct speakers in the final transcript — richer than just labels:
    /// each carries `speakerId` and `isMicrophone` so the recordings-list
    /// row can render pill chips ("You" / `Unknown #N` / named) with the
    /// right tint without re-decoding `metadata.json`.
    public let speakers: [RecordingSpeaker]
    /// Whether a `final.md` is present (the recording has been refined).
    public let isRefined: Bool
    /// User-assigned title from the `title.txt` sidecar (spec §4.1), `nil`
    /// when none is set. UI-owned; decoded at scan time like everything else.
    public let customTitle: String?

    public init(
        id: String,
        recordingStart: Date,
        folderURL: URL,
        durationSeconds: Double,
        speakers: [RecordingSpeaker],
        isRefined: Bool,
        customTitle: String? = nil
    ) {
        self.id = id
        self.recordingStart = recordingStart
        self.folderURL = folderURL
        self.durationSeconds = durationSeconds
        self.speakers = speakers
        self.isRefined = isRefined
        self.customTitle = customTitle
    }

    /// The display name shown in the list — the recording folder's basename.
    public var displayName: String { folderURL.lastPathComponent }

    /// Human title — the custom title when one is set, else the date-based
    /// default. The one source for the detail header and notifications
    /// (spec §4.1); list rows compose their own time · duration line.
    public var displayTitle: String {
        customTitle ?? defaultTitle
    }

    /// The date-based default title ("Today at 2:30 PM"), regardless of any
    /// custom title — the detail header shows it as a caption under a custom
    /// title.
    public var defaultTitle: String {
        Self.displayTitle(for: recordingStart, relativeTo: Date())
    }

    /// Injectable-now variant for deterministic tests.
    public static func displayTitle(for start: Date, relativeTo now: Date) -> String {
        let cal = Calendar.current
        let time = start.formatted(date: .omitted, time: .shortened)
        if cal.isDate(start, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(start, inSameDayAs: yesterday) { return "Yesterday at \(time)" }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    /// The recording's refined transcript (`final.md`) — present once a
    /// refine pass has completed. Derived here so views read transcripts
    /// without touching `RecordingFolder`'s file-name constants.
    public var finalURL: URL {
        folderURL.appendingPathComponent(RecordingFolder.FileName.final)
    }

    /// The recording's provisional live transcript (`live.md`).
    public var liveURL: URL {
        folderURL.appendingPathComponent(RecordingFolder.FileName.live)
    }

    /// Format `durationSeconds` as `M:SS` when shorter than an hour, else
    /// `H:MM:SS`. Truncates fractional seconds. Negative or NaN inputs
    /// (defensive — `metadata.json` is trusted, but the field is `Double`)
    /// collapse to `0:00`.
    public static func formatDuration(_ durationSeconds: Double) -> String {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return "0:00"
        }
        let total = Int(durationSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

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
            speakers: metadata.speakers.map {
                RecordingSpeaker(
                    label: $0.label,
                    speakerId: $0.speakerId,
                    isMicrophone: $0.isMicrophone)
            },
            isRefined: isRefined,
            customTitle: RecordingTitleStore.read(folderURL: folderURL))
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
            isRefined: false,
            customTitle: RecordingTitleStore.read(folderURL: folderURL))
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
