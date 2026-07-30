import Foundation

/// The payload of a PulsarTrace event — the type-specific fields that sit
/// alongside the common envelope (§8.13).
///
/// Each concrete event type conforms to this. `eventType` and `schemaVersion`
/// are static so the registry and writer can stamp the envelope without an
/// instance. `version` starts at 1 per type and bumps only on a breaking
/// schema change (PT-R80, PT-R85).
public protocol EventPayload: Encodable, Sendable {
    /// The `type` string written into the envelope (e.g. `app_started`).
    static var eventType: String { get }
    /// The per-type schema `version` (PT-R80). Starts at 1.
    static var schemaVersion: Int { get }
}

extension EventPayload {
    public static var schemaVersion: Int { 1 }
}

// MARK: - System events

/// `app_started` — emitted once when the engine/CLI process starts (§8.13).
///
/// The canonical payload is `{version, macos_version}`. The envelope
/// already owns a `version` field (the per-type schema version, PT-R80), so the
/// app-version field is serialized as `app_version` to avoid a key collision
/// in the merged JSON object. See PT-P1-D5.
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

// MARK: - Model-download events

/// `model_downloaded` — emitted once after a model is downloaded. Every current
/// model is an SDK-managed CoreML bundle (Parakeet / WhisperKit / the FluidAudio
/// diarizer): a directory tree the SDK fetches, with no single-file pin to
/// verify, so the `sha256` field carries a computed `DirectoryDigest` of the
/// bundle tree as the model's content identity (PT-P5-D2, PT-R109). Older
/// (pre-ANE) records may instead carry a single-file model's SHA-256 pin; the
/// field name is unchanged for schema stability.
///
/// `source_host` is the bare hostname (`huggingface.co`), never a full URL with
/// query params — invariant 7 (no full paths in logs) and the no-telemetry
/// rule both apply.
public struct ModelDownloadedEvent: EventPayload {
    public static let eventType = "model_downloaded"

    /// Short model name, e.g. `base` / `large-v3`.
    public let modelName: String
    /// Total bundle-tree size in bytes (`DirectoryDigest.totalBytes`).
    public let sizeBytes: Int
    /// The lowercase-hex bundle-tree `DirectoryDigest` (PT-P5-D2) — the model's
    /// content identity. (Older records may carry a single-file SHA-256 pin.)
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

// MARK: - Refinement lifecycle events

/// `refinement_started` — emitted once when `pulsartrace refine` begins work on
/// a recording, before any transcription/diarization (§8.13).
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
/// `final.md` and `metadata.json` to disk (§8.13).
///
/// Without a configured speaker library, every identified speaker is "new":
/// `speakersNew` equals `speakersIdentified` and `speakersMatched` is 0. When a
/// library is reconciled against, these split meaningfully.
public struct RefinementCompletedEvent: EventPayload {
    public static let eventType = "refinement_completed"

    public let recordingId: String
    /// Wall-clock seconds the refine pass took.
    public let durationSeconds: Double
    /// Total distinct speakers in the final transcript.
    public let speakersIdentified: Int
    /// Speakers not matched to the library (all of them when no library is
    /// configured).
    public let speakersNew: Int
    /// Speakers matched to an existing library entry (0 when no library is
    /// configured).
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

/// `refinement_failed` — emitted when a refine pass aborts (§8.13).
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

// MARK: - File-operation events

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
/// (a re-refine, PT-R48, or a speaker rename/merge).
///
/// `reason` is a stable code: a re-refine pass emits `re_refine`. Always paired
/// with the cause that triggered it (Hard Invariant #8) — for a re-refine the
/// cause is the `refinement_started` of that pass.
public struct FinalMDRewrittenEvent: EventPayload {
    public static let eventType = "final_md_rewritten"

    public let recordingId: String
    public let pathBasename: String
    public let sha256: String
    /// Why the file was rewritten — e.g. `re_refine`.
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
/// `live.md` (§8.13). The `live.md` is preserved as `.live.md.bak`.
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

// MARK: - Live-pass events

/// `live_md_started` — emitted when a recording's `live.md` is created at
/// session start (PT-R35a). The payload is `{recording_id,
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

// MARK: - Recording-lifecycle events

/// `recording_started` — emitted by `pulsartrace-capture` once a recording
/// session begins producing audio (§8.13).
///
/// Causal order: emitted after hardware capture has started and the first
/// frame has reached a socket — not at socket bind time — so a consumer
/// reacting to this event knows audio is genuinely flowing.
public struct RecordingStartedEvent: EventPayload {
    public static let eventType = "recording_started"

    /// The recording ID (`rec_<short>`) for this session.
    public let recordingId: String
    /// Basename of the recording's output folder — never a full path (Inv. #7).
    public let outputDirBasename: String
    /// The microphone device in use (its localized name), or `none`.
    public let micDevice: String
    /// Whether system-audio capture is enabled for this session (PT-R6).
    public let systemAudioEnabled: Bool
    /// The live model name used for the live pass.
    public let modelLive: String

    public init(
        recordingId: String,
        outputDirBasename: String,
        micDevice: String,
        systemAudioEnabled: Bool,
        modelLive: String
    ) {
        self.recordingId = recordingId
        self.outputDirBasename = outputDirBasename
        self.micDevice = micDevice
        self.systemAudioEnabled = systemAudioEnabled
        self.modelLive = modelLive
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case outputDirBasename = "output_dir_basename"
        case micDevice = "mic_device"
        case systemAudioEnabled = "system_audio_enabled"
        case modelLive = "model_live"
    }
}

/// `recording_paused` — emitted by `pulsartrace-capture` when capture pauses
/// mid-session (§8.13): the Mac went to sleep (PT-R7) or the active audio
/// device changed (PT-R8).
public struct RecordingPausedEvent: EventPayload {
    public static let eventType = "recording_paused"

    public let recordingId: String
    /// Why capture paused — a stable code: `sleep` or `device_change`.
    public let reason: String

    public init(recordingId: String, reason: String) {
        self.recordingId = recordingId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case reason
    }
}

/// `recording_resumed` — emitted by `pulsartrace-capture` when capture resumes
/// after a pause (§8.13). Always paired with the `recording_paused`
/// that preceded it (Hard Invariant #8).
public struct RecordingResumedEvent: EventPayload {
    public static let eventType = "recording_resumed"

    public let recordingId: String
    /// Why capture had paused — `sleep` or `device_change`.
    public let reason: String

    public init(recordingId: String, reason: String) {
        self.recordingId = recordingId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case reason
    }
}

/// `recording_stopped` — emitted by `pulsartrace-capture` once a recording
/// session ends and both audio streams are flushed (§8.13).
public struct RecordingStoppedEvent: EventPayload {
    public static let eventType = "recording_stopped"

    public let recordingId: String
    /// Total wall-clock seconds the recording captured.
    public let durationSeconds: Double
    /// Why the recording ended — a stable code: `user_stop`, `force_quit`,
    /// `sleep_timeout`, or `disk_full`.
    public let reason: String

    public init(recordingId: String, durationSeconds: Double, reason: String) {
        self.recordingId = recordingId
        self.durationSeconds = durationSeconds
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case durationSeconds = "duration_seconds"
        case reason
    }
}

/// `permission_changed` — emitted by `pulsartrace-capture` when a TCC
/// permission it depends on (Microphone or Screen Recording) changes state
/// (§8.13). Checked at launch and on the system's TCC-change
/// notification.
public struct PermissionChangedEvent: EventPayload {
    public static let eventType = "permission_changed"

    /// Which permission changed — `microphone` or `screen_recording`.
    public let permission: String
    /// Whether the permission is now granted.
    public let granted: Bool

    public init(permission: String, granted: Bool) {
        self.permission = permission
        self.granted = granted
    }

    private enum CodingKeys: String, CodingKey {
        case permission
        case granted
    }
}

// MARK: - Speaker library events

/// `speaker_created` — emitted when a new speaker is added to the persistent
/// library (§8.13). A new speaker is born either when refinement finds
/// a cluster that matches no existing library entry (`initialName` is an
/// `Unknown #N` placeholder), or via a `speaker_split`.
///
/// The `speaker_id` (`spk_<ulid>`, PT-R83) is stable forever; a later
/// `speaker_renamed` changes only the `name`.
public struct SpeakerCreatedEvent: EventPayload {
    public static let eventType = "speaker_created"

    /// Stable speaker id (`spk_<ulid>`, PT-R83).
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
/// PT-R83: `speaker_id` is unchanged across a rename — only `name` moves. The
/// library CLI `rename` does NOT retroactively rewrite past `final.md` files
/// (PT-P1-D16), so `appliedToRecordings` is empty for a
/// CLI-originated rename — no `final_md_rewritten` is paired with it.
public struct SpeakerRenamedEvent: EventPayload {
    public static let eventType = "speaker_renamed"

    public let speakerId: String
    public let oldName: String
    public let newName: String
    /// Recordings whose `final.md` was rewritten as a result. Empty for a
    /// library CLI rename (PT-P1-D16).
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
/// whose centroid is recomputed (§8.13).
public struct SpeakerMergedEvent: EventPayload {
    public static let eventType = "speaker_merged"

    /// The surviving speaker.
    public let primarySpeakerId: String
    /// The speaker folded into `primary` (soft-deleted, recoverable).
    public let mergedSpeakerId: String
    /// Recordings whose `final.md` was rewritten. Empty for a library CLI
    /// operation (PT-P1-D16).
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
/// peeled off into a brand-new speaker (§8.13). Always followed by a
/// `speaker_created` for the new speaker.
public struct SpeakerSplitEvent: EventPayload {
    public static let eventType = "speaker_split"

    /// The speaker the appearances were taken from.
    public let originalSpeakerId: String
    /// The new speaker created to hold the peeled-off appearances.
    public let newSpeakerId: String
    /// Recordings whose `final.md` was rewritten. Empty for a library CLI
    /// operation (PT-P1-D16).
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

/// `speaker_deleted` — emitted on a soft-delete (§8.13, PT-R32b). The record is
/// hidden but recoverable until `recoverableUntil` (30 days).
public struct SpeakerDeletedEvent: EventPayload {
    public static let eventType = "speaker_deleted"

    public let speakerId: String
    /// Always `true` — speaker deletes are always soft (PT-R32b).
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
/// within the 30-day recovery window (§8.13, PT-R32b undo).
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

/// `speaker_delisted` — emitted on a delist ("Don't recognize this speaker"):
/// the speaker is excluded from future matching, hidden from the live list, and
/// their token is stripped from past `final.md` labels. Soft, recoverable for
/// 30 days; the cause is logged before the paired `final_md_rewritten` events
/// (Hard Invariant #8).
public struct SpeakerDelistedEvent: EventPayload {
    public static let eventType = "speaker_delisted"

    public let speakerId: String
    /// ISO-8601 UTC instant after which the delist is no longer recoverable.
    public let recoverableUntil: String
    /// Recordings whose `final.md` was rewritten as part of the delist.
    public let appliedToRecordings: [String]

    public init(
        speakerId: String,
        recoverableUntil: String,
        appliedToRecordings: [String]
    ) {
        self.speakerId = speakerId
        self.recoverableUntil = recoverableUntil
        self.appliedToRecordings = appliedToRecordings
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case recoverableUntil = "recoverable_until"
        case appliedToRecordings = "applied_to_recordings"
    }
}

/// `speaker_undelisted` — emitted when a delist is undone within the 30-day
/// recovery window. The speaker is restored to the live list and the
/// `Unrecognized` token in affected `final.md` files is rewritten back to the
/// speaker's name (best-effort for co-attributed lines — see
/// `FinalMarkdownRewriter`).
public struct SpeakerUndelistedEvent: EventPayload {
    public static let eventType = "speaker_undelisted"

    public let speakerId: String
    /// Recordings whose `final.md` was rewritten as part of the undelist.
    public let appliedToRecordings: [String]

    public init(speakerId: String, appliedToRecordings: [String]) {
        self.speakerId = speakerId
        self.appliedToRecordings = appliedToRecordings
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case appliedToRecordings = "applied_to_recordings"
    }
}

/// `speaker_centroid_updated` — emitted when a returning speaker's centroid is
/// refined by a new appearance via the running-mean update (§8.13, PT-R30).
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

/// PT-P8-R3 / PT-P8-R10 — the owner voice profile changed. Payload carries
/// provenance and count only — never embedding values (PT-R84).
public struct OwnerProfileUpdatedEvent: EventPayload {
    public static let eventType = "owner_profile_updated"
    public static let schemaVersion = 1

    public let source: String       // passive_refine | backfill | mic_diarized_refine | owner_designated
    public let sampleCount: Int

    public init(source: String, sampleCount: Int) {
        self.source = source
        self.sampleCount = sampleCount
    }

    private enum CodingKeys: String, CodingKey {
        case source, sampleCount = "sample_count"
    }
}

/// `library_backup_created` — emitted after the speaker-library SQLite file is
/// copied to its last-good `.bak` ahead of a mutating write (§8.13, PT-R32a edge
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
/// (§8.13, edge case "library corrupted").
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
