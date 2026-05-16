import Foundation

/// The payload of a PulsarTrace event — the type-specific fields that sit
/// alongside the common envelope (§8.13).
///
/// Each concrete event type conforms to this. `eventType` and `schemaVersion`
/// are static so the registry and writer can stamp the envelope without an
/// instance. `version` starts at 1 per type and bumps only on a breaking
/// schema change (R80, R85).
public protocol EventPayload: Encodable, Sendable {
    /// The `type` string written into the envelope (e.g. `app_started`).
    static var eventType: String { get }
    /// The per-type schema `version` (R80). Starts at 1.
    static var schemaVersion: Int { get }
}

extension EventPayload {
    public static var schemaVersion: Int { 1 }
}

// MARK: - System events (Epic 1)

/// `app_started` — emitted once when the engine/CLI process starts (§8.13).
///
/// The PRD lists this payload as `{version, macos_version}`. The envelope
/// already owns a `version` field (the per-type schema version, R80), so the
/// app-version field is serialized as `app_version` to avoid a key collision
/// in the merged JSON object. See DECISIONS.md (D5).
public struct AppStartedEvent: EventPayload {
    public static let eventType = "app_started"

    /// PulsarTrace application version string.
    public let version: String
    /// Host macOS version, e.g. `26.3.1`.
    public let macosVersion: String

    public init(version: String, macosVersion: String) {
        self.version = version
        self.macosVersion = macosVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version = "app_version"
        case macosVersion = "macos_version"
    }
}

/// `app_stopped` — emitted once when the engine/CLI process exits cleanly.
///
/// Same `app_version` serialization rationale as `AppStartedEvent`.
public struct AppStoppedEvent: EventPayload {
    public static let eventType = "app_stopped"

    public let version: String
    public let macosVersion: String

    public init(version: String, macosVersion: String) {
        self.version = version
        self.macosVersion = macosVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version = "app_version"
        case macosVersion = "macos_version"
    }
}

// MARK: - System events (Epic 2)

/// `model_downloaded` — emitted once after a whisper model is downloaded *and*
/// its SHA-256 verified (R54d). A failed/corrupt download emits nothing — the
/// file is deleted and the download retried; only a verified model is an event.
///
/// `source_host` is the bare hostname (`huggingface.co`), never a full URL with
/// query params — invariant 7 (no full paths in logs) and the no-telemetry
/// rule both apply.
public struct ModelDownloadedEvent: EventPayload {
    public static let eventType = "model_downloaded"

    /// Short model name, e.g. `base` / `large-v3`.
    public let modelName: String
    /// Verified file size in bytes.
    public let sizeBytes: Int
    /// The lowercase-hex SHA-256 the file was verified against.
    public let sha256: String
    /// Bare hostname the model came from (e.g. `huggingface.co`).
    public let sourceHost: String

    public init(modelName: String, sizeBytes: Int, sha256: String, sourceHost: String) {
        self.modelName = modelName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.sourceHost = sourceHost
    }

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case sizeBytes = "size_bytes"
        case sha256
        case sourceHost = "source_host"
    }
}

// MARK: - Refinement lifecycle events (Epic 4)

/// `refinement_started` — emitted once when `pulsartrace refine` begins work on
/// a recording, before any transcription/diarization (§8.13, Epic 4).
///
/// Causal order: this is the *first* event a refine emits, so a consumer
/// tailing the log sees the cause before any of its file-write effects.
public struct RefinementStartedEvent: EventPayload {
    public static let eventType = "refinement_started"

    /// The recording ID (`rec_<short>`) being refined.
    public let recordingId: String
    /// The whisper model name used for the refine pass (e.g. `large-v3`).
    public let modelRefine: String

    public init(recordingId: String, modelRefine: String) {
        self.recordingId = recordingId
        self.modelRefine = modelRefine
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case modelRefine = "model_refine"
    }
}

/// `refinement_completed` — emitted once, last, after a refine pass has written
/// `final.md` and `metadata.json` to disk (§8.13, Epic 4).
///
/// For Epic 4 there is no speaker library yet, so every identified speaker is
/// "new": `speakersNew` equals `speakersIdentified` and `speakersMatched` is 0.
/// Epic 5 reconciles against the library and these split meaningfully.
public struct RefinementCompletedEvent: EventPayload {
    public static let eventType = "refinement_completed"

    public let recordingId: String
    /// Wall-clock seconds the refine pass took.
    public let durationSeconds: Double
    /// Total distinct speakers in the final transcript.
    public let speakersIdentified: Int
    /// Speakers not matched to the library (Epic 4: all of them).
    public let speakersNew: Int
    /// Speakers matched to an existing library entry (Epic 4: always 0).
    public let speakersMatched: Int

    public init(
        recordingId: String,
        durationSeconds: Double,
        speakersIdentified: Int,
        speakersNew: Int,
        speakersMatched: Int
    ) {
        self.recordingId = recordingId
        self.durationSeconds = durationSeconds
        self.speakersIdentified = speakersIdentified
        self.speakersNew = speakersNew
        self.speakersMatched = speakersMatched
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case durationSeconds = "duration_seconds"
        case speakersIdentified = "speakers_identified"
        case speakersNew = "speakers_new"
        case speakersMatched = "speakers_matched"
    }
}

/// `refinement_failed` — emitted when a refine pass aborts (§8.13, Epic 4).
///
/// `errorClass` is a coarse, stable category (never a raw error string with a
/// file path in it — Hard Invariant #7). `retryAvailable` tells a consumer
/// whether re-running `refine` could succeed.
public struct RefinementFailedEvent: EventPayload {
    public static let eventType = "refinement_failed"

    public let recordingId: String
    /// Coarse failure category, e.g. `transcription`, `diarization`, `io`, `input`.
    public let errorClass: String
    /// Whether re-running `refine` could plausibly succeed.
    public let retryAvailable: Bool

    public init(recordingId: String, errorClass: String, retryAvailable: Bool) {
        self.recordingId = recordingId
        self.errorClass = errorClass
        self.retryAvailable = retryAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case errorClass = "error_class"
        case retryAvailable = "retry_available"
    }
}

// MARK: - File-operation events (Epic 4)

/// `final_md_written` — emitted after `final.md` is durably on disk for the
/// first time (no prior `final.md` existed). Category: `file_operations`.
///
/// Causal order: emitted *after* the atomic rename completes, so a consumer
/// that reacts to this event will always find the file present.
public struct FinalMDWrittenEvent: EventPayload {
    public static let eventType = "final_md_written"

    public let recordingId: String
    /// Basename only (`final.md`) — never a full path (Hard Invariant #7).
    public let pathBasename: String
    /// Lowercase-hex SHA-256 of the written file's bytes.
    public let sha256: String

    public init(recordingId: String, pathBasename: String, sha256: String) {
        self.recordingId = recordingId
        self.pathBasename = pathBasename
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case pathBasename = "path_basename"
        case sha256
    }
}

/// `final_md_rewritten` — emitted when an existing `final.md` is replaced
/// (a re-refine, R27, or — in Epic 5 — a speaker rename/merge).
///
/// `reason` is a stable code: Epic 4 emits `re_refine`. Always paired with the
/// cause that triggered it (Hard Invariant #8) — for Epic 4 the cause is the
/// `refinement_started` of the re-refine pass.
public struct FinalMDRewrittenEvent: EventPayload {
    public static let eventType = "final_md_rewritten"

    public let recordingId: String
    public let pathBasename: String
    public let sha256: String
    /// Why the file was rewritten — Epic 4: `re_refine`.
    public let reason: String

    public init(recordingId: String, pathBasename: String, sha256: String, reason: String) {
        self.recordingId = recordingId
        self.pathBasename = pathBasename
        self.sha256 = sha256
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case pathBasename = "path_basename"
        case sha256
        case reason
    }
}

/// `live_md_replaced_by_final` — emitted when refinement supersedes an existing
/// `live.md` (§8.13, Epic 4). The `live.md` is preserved as `.live.md.bak`.
public struct LiveMDReplacedByFinalEvent: EventPayload {
    public static let eventType = "live_md_replaced_by_final"

    public let recordingId: String

    public init(recordingId: String) {
        self.recordingId = recordingId
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
    }
}

// MARK: - Live-pass events (Epic 6)

/// `live_md_started` — emitted when a recording's `live.md` is created at
/// session start (R35a). Per PRD §8.13 the payload is `{recording_id,
/// path_basename}`.
///
/// Causal order (Hard Invariant #8): emitted *after* `live.md` exists on disk
/// with its marker + header, so a consumer reacting to this event always finds
/// the file present and tail-able. The streaming pass then appends utterance
/// lines; the post-pass eventually emits `live_md_replaced_by_final`.
public struct LiveMDStartedEvent: EventPayload {
    public static let eventType = "live_md_started"

    /// The recording whose live pass started.
    public let recordingId: String
    /// Basename only (`live.md`) — never a full path (Hard Invariant #7).
    public let pathBasename: String

    public init(recordingId: String, pathBasename: String) {
        self.recordingId = recordingId
        self.pathBasename = pathBasename
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case pathBasename = "path_basename"
    }
}

// MARK: - Speaker library events (Epic 5)

/// `speaker_created` — emitted when a new speaker is added to the persistent
/// library (§8.13, Epic 5). A new speaker is born either when refinement finds
/// a cluster that matches no existing library entry (`initialName` is an
/// `Unknown #N` placeholder), or via a `speaker_split`.
///
/// The `speaker_id` (`spk_<ulid>`, R83) is stable forever; a later
/// `speaker_renamed` changes only the `name`.
public struct SpeakerCreatedEvent: EventPayload {
    public static let eventType = "speaker_created"

    /// Stable speaker id (`spk_<ulid>`, R83).
    public let speakerId: String
    /// The name the speaker was created with — an `Unknown #N` placeholder for
    /// a refinement-discovered speaker. The events log MAY carry user-assigned
    /// names (it is local-only); the operational log must not.
    public let initialName: String
    /// The recording whose refinement first surfaced this speaker.
    public let sourceRecordingId: String

    public init(speakerId: String, initialName: String, sourceRecordingId: String) {
        self.speakerId = speakerId
        self.initialName = initialName
        self.sourceRecordingId = sourceRecordingId
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case initialName = "initial_name"
        case sourceRecordingId = "source_recording_id"
    }
}

/// `speaker_renamed` — emitted when a speaker's display name changes (§8.13).
///
/// R83: `speaker_id` is unchanged across a rename — only `name` moves. Epic 5
/// CLI `rename` does NOT retroactively rewrite past `final.md` files (that is
/// Epic 8 scope, DECISIONS.md D16), so `appliedToRecordings` is empty for an
/// Epic 5-originated rename — no `final_md_rewritten` is paired with it.
public struct SpeakerRenamedEvent: EventPayload {
    public static let eventType = "speaker_renamed"

    public let speakerId: String
    public let oldName: String
    public let newName: String
    /// Recordings whose `final.md` was rewritten as a result. Empty for an
    /// Epic 5 CLI rename (the rewrite is Epic 8 scope — D16).
    public let appliedToRecordings: [String]

    public init(
        speakerId: String,
        oldName: String,
        newName: String,
        appliedToRecordings: [String]
    ) {
        self.speakerId = speakerId
        self.oldName = oldName
        self.newName = newName
        self.appliedToRecordings = appliedToRecordings
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case oldName = "old_name"
        case newName = "new_name"
        case appliedToRecordings = "applied_to_recordings"
    }
}

/// `speaker_merged` — emitted when two speakers are merged: the `merged`
/// speaker is soft-deleted and its appearances re-attributed to `primary`,
/// whose centroid is recomputed (§8.13, Epic 5).
public struct SpeakerMergedEvent: EventPayload {
    public static let eventType = "speaker_merged"

    /// The surviving speaker.
    public let primarySpeakerId: String
    /// The speaker folded into `primary` (soft-deleted, recoverable).
    public let mergedSpeakerId: String
    /// Recordings whose `final.md` was rewritten. Empty for Epic 5 (D16).
    public let appliedToRecordings: [String]

    public init(
        primarySpeakerId: String,
        mergedSpeakerId: String,
        appliedToRecordings: [String]
    ) {
        self.primarySpeakerId = primarySpeakerId
        self.mergedSpeakerId = mergedSpeakerId
        self.appliedToRecordings = appliedToRecordings
    }

    private enum CodingKeys: String, CodingKey {
        case primarySpeakerId = "primary_speaker_id"
        case mergedSpeakerId = "merged_speaker_id"
        case appliedToRecordings = "applied_to_recordings"
    }
}

/// `speaker_split` — emitted when a subset of one speaker's appearances is
/// peeled off into a brand-new speaker (§8.13, Epic 5). Always followed by a
/// `speaker_created` for the new speaker.
public struct SpeakerSplitEvent: EventPayload {
    public static let eventType = "speaker_split"

    /// The speaker the appearances were taken from.
    public let originalSpeakerId: String
    /// The new speaker created to hold the peeled-off appearances.
    public let newSpeakerId: String
    /// Recordings whose `final.md` was rewritten. Empty for Epic 5 (D16).
    public let appliedToRecordings: [String]

    public init(
        originalSpeakerId: String,
        newSpeakerId: String,
        appliedToRecordings: [String]
    ) {
        self.originalSpeakerId = originalSpeakerId
        self.newSpeakerId = newSpeakerId
        self.appliedToRecordings = appliedToRecordings
    }

    private enum CodingKeys: String, CodingKey {
        case originalSpeakerId = "original_speaker_id"
        case newSpeakerId = "new_speaker_id"
        case appliedToRecordings = "applied_to_recordings"
    }
}

/// `speaker_deleted` — emitted on a soft-delete (§8.13, R32b). The record is
/// hidden but recoverable until `recoverableUntil` (30 days).
public struct SpeakerDeletedEvent: EventPayload {
    public static let eventType = "speaker_deleted"

    public let speakerId: String
    /// Always `true` — Epic 5 deletes are always soft (R32b).
    public let softDelete: Bool
    /// ISO-8601 UTC instant after which the record is no longer recoverable.
    public let recoverableUntil: String

    public init(speakerId: String, softDelete: Bool = true, recoverableUntil: String) {
        self.speakerId = speakerId
        self.softDelete = softDelete
        self.recoverableUntil = recoverableUntil
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case softDelete = "soft_delete"
        case recoverableUntil = "recoverable_until"
    }
}

/// `speaker_undeleted` — emitted when a soft-deleted speaker is restored
/// within the 30-day recovery window (§8.13, R32b undo).
public struct SpeakerUndeletedEvent: EventPayload {
    public static let eventType = "speaker_undeleted"

    public let speakerId: String

    public init(speakerId: String) {
        self.speakerId = speakerId
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
    }
}

/// `speaker_unmerged` — emitted when a merge is undone: the merged speaker is
/// restored and its appearances are moved back off the primary (§8.13).
public struct SpeakerUnmergedEvent: EventPayload {
    public static let eventType = "speaker_unmerged"

    public let primarySpeakerId: String
    public let mergedSpeakerId: String

    public init(primarySpeakerId: String, mergedSpeakerId: String) {
        self.primarySpeakerId = primarySpeakerId
        self.mergedSpeakerId = mergedSpeakerId
    }

    private enum CodingKeys: String, CodingKey {
        case primarySpeakerId = "primary_speaker_id"
        case mergedSpeakerId = "merged_speaker_id"
    }
}

/// `speaker_unsplit` — emitted when a split is undone: the new speaker is
/// soft-deleted and its appearances returned to the original (§8.13).
public struct SpeakerUnsplitEvent: EventPayload {
    public static let eventType = "speaker_unsplit"

    public let originalSpeakerId: String
    public let newSpeakerId: String

    public init(originalSpeakerId: String, newSpeakerId: String) {
        self.originalSpeakerId = originalSpeakerId
        self.newSpeakerId = newSpeakerId
    }

    private enum CodingKeys: String, CodingKey {
        case originalSpeakerId = "original_speaker_id"
        case newSpeakerId = "new_speaker_id"
    }
}

/// `speaker_centroid_updated` — emitted when a returning speaker's centroid is
/// refined by a new appearance via the running-mean update (§8.13, R30).
public struct SpeakerCentroidUpdatedEvent: EventPayload {
    public static let eventType = "speaker_centroid_updated"

    public let speakerId: String
    /// The recording whose appearance was averaged into the centroid.
    public let recordingId: String
    /// The speaker's appearance count *after* this update.
    public let appearanceCount: Int

    public init(speakerId: String, recordingId: String, appearanceCount: Int) {
        self.speakerId = speakerId
        self.recordingId = recordingId
        self.appearanceCount = appearanceCount
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case recordingId = "recording_id"
        case appearanceCount = "appearance_count"
    }
}

/// `library_backup_created` — emitted after the speaker-library SQLite file is
/// copied to its last-good `.bak` ahead of a mutating write (§8.13, R32a edge
/// case "library corrupted").
public struct LibraryBackupCreatedEvent: EventPayload {
    public static let eventType = "library_backup_created"

    /// Basename only (`speakers.sqlite.bak`) — never a full path (Invariant #7).
    public let pathBasename: String
    /// Lowercase-hex SHA-256 of the backed-up database file.
    public let sha256: String

    public init(pathBasename: String, sha256: String) {
        self.pathBasename = pathBasename
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case pathBasename = "path_basename"
        case sha256
    }
}

/// `library_corruption_detected` — emitted when the speaker-library database
/// fails to open / integrity-check and the last-good backup is restored
/// (§8.13, Epic 5 edge case "library corrupted").
public struct LibraryCorruptionDetectedEvent: EventPayload {
    public static let eventType = "library_corruption_detected"

    /// Basename of the corrupt database (`speakers.sqlite`).
    public let pathBasename: String
    /// True when a last-good backup was found and restored.
    public let recoveredFromBackup: Bool

    public init(pathBasename: String, recoveredFromBackup: Bool) {
        self.pathBasename = pathBasename
        self.recoveredFromBackup = recoveredFromBackup
    }

    private enum CodingKeys: String, CodingKey {
        case pathBasename = "path_basename"
        case recoveredFromBackup = "recovered_from_backup"
    }
}
