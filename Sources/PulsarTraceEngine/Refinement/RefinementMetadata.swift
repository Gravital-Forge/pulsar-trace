import Foundation

/// The `metadata.json` sidecar a refine pass writes next to `final.md` (PT-R39).
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

    /// Current schema version. v2: `pyannote_model` → `diarization_model`
    /// {id, revision} (PT-P5-D3 — diarization moved to the ANE; the pyannote.audio
    /// library version no longer exists).
    /// v3: `mic_diarized` + per-stream `is_microphone` (PT-P8-R10) — the mic
    /// stream can now carry several speakers, so `is_microphone` is no longer
    /// synonymous with the single `You` row.
    public static let currentSchemaVersion = 3

    /// One speaker in the refined transcript.
    public struct Speaker: Codable, Equatable, Sendable {
        /// Transcript-facing label. When a speaker library is configured this
        /// is the persistent library name (`Steve`, `Unknown #1`) for
        /// system-stream speakers; `You` for the mic stream. Without a library
        /// `final.md` files carry `Speaker_N`.
        public let label: String
        /// True for every speaker attributed to the microphone stream
        /// (PT-P8-R10; may be several — `You` plus mic-diarized guests). Before
        /// PT-P8-R1 this was synonymous with the single `You` row.
        public let isMicrophone: Bool
        /// Stable library speaker id (`spk_<ulid>`, PT-R83) — present for a
        /// system-stream speaker reconciled against the library,
        /// `nil` for `You` and for a speaker not reconciled (e.g. diarization
        /// skipped, or no library configured).
        public let speakerId: String?

        public init(label: String, isMicrophone: Bool, speakerId: String? = nil) {
            self.label = label
            self.isMicrophone = isMicrophone
            self.speakerId = speakerId
        }

        private enum CodingKeys: String, CodingKey {
            case label
            case isMicrophone = "is_microphone"
            case speakerId = "speaker_id"
        }
    }

    /// Identity of the refine-pass transcription model (WhisperKit on the ANE).
    public struct WhisperModelInfo: Codable, Equatable, Sendable {
        /// Short model name, e.g. `large-v3-turbo`, `large-v3`.
        public let name: String
        /// Model content identity. Empty for the SDK-managed CoreML bundle, which
        /// carries no single-file pin (PT-P5-D2); the `whisper_model` field name
        /// is kept unchanged for schema stability.
        public let sha256: String

        public init(name: String, sha256: String) {
            self.name = name
            self.sha256 = sha256
        }
    }

    /// Identity of the diarization model used for the refine pass.
    public struct DiarizationModelInfo: Codable, Equatable, Sendable {
        /// Model id, e.g. `FluidInference/speaker-diarization-coreml`.
        public let id: String
        /// Content digest of the model directory (DirectoryDigest SHA-256) —
        /// the speaker library's centroid-compatibility key (PT-P5-D3).
        public let revision: String

        public init(id: String, revision: String) {
            self.id = id
            self.revision = revision
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
    /// Diarization model identity (nil if diarization was skipped, e.g. no speech).
    public let diarizationModel: DiarizationModelInfo?
    /// Detected/used transcription language (ISO-639-1).
    public let language: String
    /// Basename of the user-supplied input (never a full path — Invariant #7).
    public let sourceBasename: String
    /// PT-P8-R10 — true when this recording's mic stream was diarized (the
    /// per-recording stamp was on). Absent in v2 files ⇒ `false`.
    public let micDiarized: Bool

    public init(
        schemaVersion: Int = RefinementMetadata.currentSchemaVersion,
        recordingId: String,
        recordingStart: String,
        refinedAt: String,
        durationSeconds: Double,
        speakers: [Speaker],
        whisperModel: WhisperModelInfo,
        diarizationModel: DiarizationModelInfo?,
        language: String,
        sourceBasename: String,
        micDiarized: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.recordingId = recordingId
        self.recordingStart = recordingStart
        self.refinedAt = refinedAt
        self.durationSeconds = durationSeconds
        self.speakers = speakers
        self.whisperModel = whisperModel
        self.diarizationModel = diarizationModel
        self.language = language
        self.sourceBasename = sourceBasename
        self.micDiarized = micDiarized
    }

    /// Tolerant decode: `mic_diarized` is absent in v2 files and defaults to
    /// `false` so an older `metadata.json` still reads (PT-P8-R10).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.recordingId = try c.decode(String.self, forKey: .recordingId)
        self.recordingStart = try c.decode(String.self, forKey: .recordingStart)
        self.refinedAt = try c.decode(String.self, forKey: .refinedAt)
        self.durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        self.speakers = try c.decode([Speaker].self, forKey: .speakers)
        self.whisperModel = try c.decode(WhisperModelInfo.self, forKey: .whisperModel)
        self.diarizationModel = try c.decodeIfPresent(
            DiarizationModelInfo.self, forKey: .diarizationModel)
        self.language = try c.decode(String.self, forKey: .language)
        self.sourceBasename = try c.decode(String.self, forKey: .sourceBasename)
        self.micDiarized =
            try c.decodeIfPresent(Bool.self, forKey: .micDiarized) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordingId = "recording_id"
        case recordingStart = "recording_start"
        case refinedAt = "refined_at"
        case durationSeconds = "duration_seconds"
        case speakers
        case whisperModel = "whisper_model"
        case diarizationModel = "diarization_model"
        case language
        case sourceBasename = "source_basename"
        case micDiarized = "mic_diarized"
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
