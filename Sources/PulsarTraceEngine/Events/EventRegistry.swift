import Foundation

/// The catalogue of event types known to this build.
///
/// `docs/events-schema.md` is the human-facing contract; this registry is the
/// machine-facing one. Later epics extend it by appending entries — the
/// `EventWriter` does not need to change. Keeping every type registered in one
/// place makes it cheap to verify "every significant operation emits exactly
/// one event" (R82) by diffing this list against the product's operations.
public enum EventRegistry {

    /// A registered event type: its `type` string and current schema version.
    public struct Entry: Sendable, Equatable {
        public let type: String
        public let version: Int
        public let category: Category

        public init(type: String, version: Int, category: Category) {
            self.type = type
            self.version = version
            self.category = category
        }
    }

    /// The five event categories from §8.13.
    public enum Category: String, Sendable {
        case recordingLifecycle = "recording_lifecycle"
        case refinementLifecycle = "refinement_lifecycle"
        case speakerLibrary = "speaker_library"
        case fileOperations = "file_operations"
        case system
    }

    /// All event types this build knows how to emit.
    ///
    /// Epic 1 registers only the `system` `app_started` / `app_stopped` pair.
    /// Later epics append their types here as they implement emission.
    public static let all: [Entry] = [
        Entry(
            type: AppStartedEvent.eventType,
            version: AppStartedEvent.schemaVersion,
            category: .system
        ),
        Entry(
            type: AppStoppedEvent.eventType,
            version: AppStoppedEvent.schemaVersion,
            category: .system
        ),
        // Epic 2: whisper model downloaded + SHA-256 verified.
        Entry(
            type: ModelDownloadedEvent.eventType,
            version: ModelDownloadedEvent.schemaVersion,
            category: .system
        ),
        // Epic 4: refinement lifecycle (`pulsartrace refine`).
        Entry(
            type: RefinementStartedEvent.eventType,
            version: RefinementStartedEvent.schemaVersion,
            category: .refinementLifecycle
        ),
        Entry(
            type: RefinementCompletedEvent.eventType,
            version: RefinementCompletedEvent.schemaVersion,
            category: .refinementLifecycle
        ),
        Entry(
            type: RefinementFailedEvent.eventType,
            version: RefinementFailedEvent.schemaVersion,
            category: .refinementLifecycle
        ),
        // Epic 4: file operations produced by a refine pass.
        Entry(
            type: FinalMDWrittenEvent.eventType,
            version: FinalMDWrittenEvent.schemaVersion,
            category: .fileOperations
        ),
        Entry(
            type: FinalMDRewrittenEvent.eventType,
            version: FinalMDRewrittenEvent.schemaVersion,
            category: .fileOperations
        ),
        Entry(
            type: LiveMDReplacedByFinalEvent.eventType,
            version: LiveMDReplacedByFinalEvent.schemaVersion,
            category: .fileOperations
        ),
        // Epic 6: live-pass file operations.
        Entry(
            type: LiveMDStartedEvent.eventType,
            version: LiveMDStartedEvent.schemaVersion,
            category: .fileOperations
        ),
        // Epic 5: speaker library operations.
        Entry(
            type: SpeakerCreatedEvent.eventType,
            version: SpeakerCreatedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerRenamedEvent.eventType,
            version: SpeakerRenamedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerMergedEvent.eventType,
            version: SpeakerMergedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerSplitEvent.eventType,
            version: SpeakerSplitEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerDeletedEvent.eventType,
            version: SpeakerDeletedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerUndeletedEvent.eventType,
            version: SpeakerUndeletedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerUnmergedEvent.eventType,
            version: SpeakerUnmergedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerUnsplitEvent.eventType,
            version: SpeakerUnsplitEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerCentroidUpdatedEvent.eventType,
            version: SpeakerCentroidUpdatedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        // Epic 5: speaker-library database health (system category).
        Entry(
            type: LibraryBackupCreatedEvent.eventType,
            version: LibraryBackupCreatedEvent.schemaVersion,
            category: .system
        ),
        Entry(
            type: LibraryCorruptionDetectedEvent.eventType,
            version: LibraryCorruptionDetectedEvent.schemaVersion,
            category: .system
        ),
    ]

    /// Look up a registered entry by its `type` string.
    public static func entry(for type: String) -> Entry? {
        all.first { $0.type == type }
    }
}
