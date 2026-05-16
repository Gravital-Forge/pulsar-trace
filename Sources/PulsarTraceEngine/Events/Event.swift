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
