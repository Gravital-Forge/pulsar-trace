import Foundation

/// One persistent speaker in the library (PT-R28).
///
/// The `id` (`spk_<ulid>`, PT-R83) is the forever-stable identity an external
/// agent keys off; `name` is a mutable display string (`Unknown #3`, `Steve`).
/// `centroid` is the running mean of every appearance embedding (PT-R30), valid
/// only within `modelRevision` (Open Question #3 / PT-P5-D3).
public struct Speaker: Sendable, Equatable, Identifiable {

    /// Stable speaker id (`spk_<ulid>`).
    public let id: String
    /// Mutable display name (`Unknown #N` placeholder or a user-assigned name).
    public var name: String
    /// Running-mean embedding centroid — 256-d for the WeSpeaker backend.
    public var centroid: [Float]
    /// Diarization-model revision (content digest, PT-P5-D3) the centroid was built
    /// under. A centroid is only comparable with embeddings from the same
    /// revision (Open Question #3 — cross-revision matches are refused).
    public var modelRevision: String
    /// Number of recording appearances folded into the centroid.
    public var appearanceCount: Int
    /// Wall-clock of the most recent appearance (ISO-8601 UTC).
    public var lastSeen: String
    /// Basename of a representative audio file for this speaker, if any
    /// (PT-R28 `sample_audio_path` — basename only, Invariant #7).
    public var sampleAudioPath: String?
    /// Wall-clock the row was created (ISO-8601 UTC).
    public let createdAt: String
    /// Soft-delete tombstone (PT-R32b): `nil` for a live speaker, an ISO-8601 UTC
    /// instant for a deleted/merged-away speaker. Recoverable for 30 days.
    public var deletedAt: String?
    /// Delist tombstone ("Don't recognize this speaker"): `nil` for a speaker
    /// the matcher considers, an ISO-8601 UTC instant for one excluded from
    /// `bestMatch` and stripped from past `final.md` labels. Soft, recoverable
    /// for 30 days. Orthogonal to `deletedAt` — a speaker can be either, or
    /// both, and `liveSpeakers()` filters on both fields.
    public var delistedAt: String?

    public init(
        id: String,
        name: String,
        centroid: [Float],
        modelRevision: String,
        appearanceCount: Int,
        lastSeen: String,
        sampleAudioPath: String?,
        createdAt: String,
        deletedAt: String? = nil,
        delistedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.centroid = centroid
        self.modelRevision = modelRevision
        self.appearanceCount = appearanceCount
        self.lastSeen = lastSeen
        self.sampleAudioPath = sampleAudioPath
        self.createdAt = createdAt
        self.deletedAt = deletedAt
        self.delistedAt = delistedAt
    }

    /// True when the speaker has been soft-deleted (PT-R32b).
    public var isDeleted: Bool { deletedAt != nil }
    /// True when the speaker has been delisted ("Don't recognize this speaker").
    public var isDelisted: Bool { delistedAt != nil }
}

/// One speaker ↔ recording appearance link (PT-R28 appearances table).
///
/// Kept as a separate table so the retroactive rewrite can enumerate every
/// `final.md` a speaker appears in and rewrite it after a rename/merge.
public struct SpeakerAppearance: Sendable, Equatable {
    /// The speaker (`spk_<ulid>`).
    public let speakerId: String
    /// The recording (`rec_<short>`).
    public let recordingId: String
    /// Basename of the recording folder, so the retroactive rewrite can locate
    /// `final.md` (basename only — Invariant #7).
    public let recordingFolderName: String
    /// Wall-clock the appearance was recorded (ISO-8601 UTC).
    public let observedAt: String

    public init(
        speakerId: String,
        recordingId: String,
        recordingFolderName: String,
        observedAt: String
    ) {
        self.speakerId = speakerId
        self.recordingId = recordingId
        self.recordingFolderName = recordingFolderName
        self.observedAt = observedAt
    }
}

/// The result of matching a cluster centroid against the library (PT-R22).
public struct SpeakerMatch: Sendable, Equatable {
    /// The matched library speaker.
    public let speaker: Speaker
    /// Cosine similarity of the query centroid to the speaker's centroid.
    public let similarity: Double
}
