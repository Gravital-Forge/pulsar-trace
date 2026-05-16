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
