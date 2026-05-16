import Foundation

/// The `metadata.json` sidecar a refine pass writes next to `final.md` (R39).
///
/// `metadata.json` is the machine-readable summary of a refined recording: an
/// AI agent or a script reads it instead of parsing `final.md` prose. It is a
/// public API surface alongside `final.md` — `schemaVersion` lets it evolve
/// SemVer-style (adding an optional field is non-breaking; removing/renaming
/// one bumps the version).
///
/// Key ordering is stable (`JSONEncoder.sortedKeys`) so a normalized snapshot
/// is byte-deterministic.
public struct RefinementMetadata: Codable, Equatable, Sendable {

    /// Current schema version. Bumped only on a breaking change to this shape.
    public static let currentSchemaVersion = 1

    /// One speaker in the refined transcript.
    public struct Speaker: Codable, Equatable, Sendable {
        /// Transcript-facing label (`You`, `Speaker_0`, `Speaker_1`, …).
        public let label: String
        /// True for the mic-stream speaker (`You`) — never diarized (R17).
        public let isMicrophone: Bool

        public init(label: String, isMicrophone: Bool) {
            self.label = label
            self.isMicrophone = isMicrophone
        }

        private enum CodingKeys: String, CodingKey {
            case label
            case isMicrophone = "is_microphone"
        }
    }

    /// Identity of the whisper model used for the refine pass.
    public struct WhisperModelInfo: Codable, Equatable, Sendable {
        /// Short model name, e.g. `large-v3`, `base`.
        public let name: String
        /// Pinned SHA-256 of the ggml model file (its version identity, R54d).
        public let sha256: String

        public init(name: String, sha256: String) {
            self.name = name
            self.sha256 = sha256
        }
    }

    /// Identity of the pyannote model used for diarization.
    public struct PyannoteModelInfo: Codable, Equatable, Sendable {
        /// Model id, e.g. `pyannote/speaker-diarization-community-1`.
        public let id: String
        /// Hugging Face hub commit SHA of the model checkpoint (D11/D12).
        public let revision: String
        /// pyannote.audio library version string.
        public let libraryVersion: String

        public init(id: String, revision: String, libraryVersion: String) {
            self.id = id
            self.revision = revision
            self.libraryVersion = libraryVersion
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case revision
            case libraryVersion = "library_version"
        }
    }

    // MARK: - Fields

    /// `metadata.json` schema version.
    public let schemaVersion: Int
    /// The recording id (`rec_<short>`).
    public let recordingId: String
    /// Wall-clock at which the recording started (ISO-8601 UTC).
    public let recordingStart: String
    /// Wall-clock at which this refine pass started (ISO-8601 UTC).
    public let refinedAt: String
    /// Audio duration in seconds (the longer of the streams).
    public let durationSeconds: Double
    /// Distinct speakers in the final transcript.
    public let speakers: [Speaker]
    /// Whisper model identity.
    public let whisperModel: WhisperModelInfo
    /// pyannote model identity (nil if diarization was skipped, e.g. no speech).
    public let pyannoteModel: PyannoteModelInfo?
    /// Detected/used transcription language (ISO-639-1).
    public let language: String
    /// Basename of the user-supplied input (never a full path — Invariant #7).
    public let sourceBasename: String

    public init(
        schemaVersion: Int = RefinementMetadata.currentSchemaVersion,
        recordingId: String,
        recordingStart: String,
        refinedAt: String,
        durationSeconds: Double,
        speakers: [Speaker],
        whisperModel: WhisperModelInfo,
        pyannoteModel: PyannoteModelInfo?,
        language: String,
        sourceBasename: String
    ) {
        self.schemaVersion = schemaVersion
        self.recordingId = recordingId
        self.recordingStart = recordingStart
        self.refinedAt = refinedAt
        self.durationSeconds = durationSeconds
        self.speakers = speakers
        self.whisperModel = whisperModel
        self.pyannoteModel = pyannoteModel
        self.language = language
        self.sourceBasename = sourceBasename
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordingId = "recording_id"
        case recordingStart = "recording_start"
        case refinedAt = "refined_at"
        case durationSeconds = "duration_seconds"
        case speakers
        case whisperModel = "whisper_model"
        case pyannoteModel = "pyannote_model"
        case language
        case sourceBasename = "source_basename"
    }

    /// Encode to pretty, stable-key-order JSON bytes for the sidecar file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)  // POSIX-clean trailing newline.
        return data
    }
}
