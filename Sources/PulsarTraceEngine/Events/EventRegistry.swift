import Foundation

/// The catalogue of event types known to this build.
///
/// `.erratum/product/architecture/events-log.md` is the human-facing contract; this registry is the
/// machine-facing one. New event types extend it by appending entries — the
/// `EventWriter` does not need to change. Keeping every type registered in one
/// place makes it cheap to verify "every significant operation emits exactly
/// one event" (PT-R82) by diffing this list against the product's operations.
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
        // whisper model downloaded + SHA-256 verified.
        Entry(
            type: ModelDownloadedEvent.eventType,
            version: ModelDownloadedEvent.schemaVersion,
            category: .system
        ),
        // Refinement lifecycle (`pulsartrace refine`).
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
        // File operations produced by a refine pass.
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
        // Live-pass file operations.
        Entry(
            type: LiveMDStartedEvent.eventType,
            version: LiveMDStartedEvent.schemaVersion,
            category: .fileOperations
        ),
        // Speaker library operations.
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
            type: SpeakerDelistedEvent.eventType,
            version: SpeakerDelistedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerUndelistedEvent.eventType,
            version: SpeakerUndelistedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: SpeakerCentroidUpdatedEvent.eventType,
            version: SpeakerCentroidUpdatedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        // PT-R137 / PT-R144 — owner voice profile changed (beside the library).
        Entry(
            type: OwnerProfileUpdatedEvent.eventType,
            version: OwnerProfileUpdatedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        // PT-R140 — owner reassignment ("this is me" / "not me").
        Entry(
            type: OwnerDesignatedEvent.eventType,
            version: OwnerDesignatedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        Entry(
            type: OwnerDemotedEvent.eventType,
            version: OwnerDemotedEvent.schemaVersion,
            category: .speakerLibrary
        ),
        // Speaker-library database health (system category).
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
        // Recording lifecycle (`pulsartrace-capture`).
        Entry(
            type: RecordingStartedEvent.eventType,
            version: RecordingStartedEvent.schemaVersion,
            category: .recordingLifecycle
        ),
        Entry(
            type: RecordingPausedEvent.eventType,
            version: RecordingPausedEvent.schemaVersion,
            category: .recordingLifecycle
        ),
        Entry(
            type: RecordingResumedEvent.eventType,
            version: RecordingResumedEvent.schemaVersion,
            category: .recordingLifecycle
        ),
        Entry(
            type: RecordingStoppedEvent.eventType,
            version: RecordingStoppedEvent.schemaVersion,
            category: .recordingLifecycle
        ),
        // TCC permission changes (system category).
        Entry(
            type: PermissionChangedEvent.eventType,
            version: PermissionChangedEvent.schemaVersion,
            category: .system
        ),
    ]

    /// Look up a registered entry by its `type` string.
    public static func entry(for type: String) -> Entry? {
        all.first { $0.type == type }
    }
}
