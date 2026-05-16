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
