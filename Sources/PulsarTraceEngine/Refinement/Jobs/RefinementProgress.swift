// Sources/PulsarTraceEngine/Refinement/Jobs/RefinementProgress.swift
import Foundation

/// The `refine-progress.json` checkpoint file written into the recording
/// folder by `ResumableRefiner` (D-Q5/D-Q6).
///
/// Lives next to `metadata.json` so the recording folder is self-contained:
/// copying the folder to another machine carries the in-flight refine state.
/// The queue-side `RefinementJob` is just a pointer; this file is the work.
public struct RefinementProgress: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1

    /// One VAD region of one stream — `[startMillis, endMillis)` in recording
    /// time. Indices in `completed*RegionIndices` refer to positions in the
    /// matching `*Regions` array.
    public struct RegionWindow: Codable, Equatable, Sendable {
        public let startMillis: Int
        public let endMillis: Int

        private enum CodingKeys: String, CodingKey {
            case startMillis = "start_ms"
            case endMillis = "end_ms"
        }

        public init(startMillis: Int, endMillis: Int) {
            self.startMillis = startMillis
            self.endMillis = endMillis
        }
    }

    /// One transcript segment — same shape `TranscriptSegment` serializes to.
    /// Kept structurally identical so the merge step at the end can lift
    /// segments back into `TranscriptSegment`s with no schema translation.
    public struct PartialSegment: Codable, Equatable, Sendable {
        public let startMillis: Int
        public let endMillis: Int
        public let text: String
        public let regionIndex: Int  // which region produced this segment

        private enum CodingKeys: String, CodingKey {
            case startMillis = "start_ms"
            case endMillis = "end_ms"
            case text
            case regionIndex = "region_index"
        }

        public init(startMillis: Int, endMillis: Int, text: String, regionIndex: Int) {
            self.startMillis = startMillis
            self.endMillis = endMillis
            self.text = text
            self.regionIndex = regionIndex
        }
    }

    public var schemaVersion: Int
    public var jobId: String
    public var recordingId: String
    public var stage: RefinementJobState.Stage

    public var systemRegions: [RegionWindow]
    public var completedSystemRegionIndices: [Int]
    public var systemSegments: [PartialSegment]

    public var micRegions: [RegionWindow]
    public var completedMicRegionIndices: [Int]
    public var micSegments: [PartialSegment]

    /// Language detected on the first decoded region; reused for later regions
    /// so a quiet region's auto-detect can't disagree.
    public var language: String?

    public var lastCheckpointAt: Date

    /// Description of the most recent error that caused this job to fail or
    /// abort, with filesystem paths redacted. `nil` on a healthy job. Persists
    /// across a retry so the next user / debugger has something concrete to
    /// look at — `RefinementJobState.failed.errorClass` is a coarse bucket.
    public var lastError: String?

    public init(
        schemaVersion: Int,
        jobId: String,
        recordingId: String,
        stage: RefinementJobState.Stage,
        systemRegions: [RegionWindow],
        completedSystemRegionIndices: [Int],
        systemSegments: [PartialSegment],
        micRegions: [RegionWindow],
        completedMicRegionIndices: [Int],
        micSegments: [PartialSegment],
        language: String?,
        lastCheckpointAt: Date,
        lastError: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.jobId = jobId
        self.recordingId = recordingId
        self.stage = stage
        self.systemRegions = systemRegions
        self.completedSystemRegionIndices = completedSystemRegionIndices
        self.systemSegments = systemSegments
        self.micRegions = micRegions
        self.completedMicRegionIndices = completedMicRegionIndices
        self.micSegments = micSegments
        self.language = language
        self.lastCheckpointAt = lastCheckpointAt
        self.lastError = lastError
    }

    public static func empty(jobId: String, recordingId: String) -> RefinementProgress {
        RefinementProgress(
            schemaVersion: currentSchemaVersion,
            jobId: jobId,
            recordingId: recordingId,
            stage: .resolvingInput,
            systemRegions: [],
            completedSystemRegionIndices: [],
            systemSegments: [],
            micRegions: [],
            completedMicRegionIndices: [],
            micSegments: [],
            language: nil,
            lastCheckpointAt: Date(timeIntervalSince1970: 0))
    }

    /// The lowest system-stream region index not yet completed, or `nil` if
    /// every region in `systemRegions` has been processed.
    public var nextSystemRegionIndex: Int? {
        let done = Set(completedSystemRegionIndices)
        for i in systemRegions.indices where !done.contains(i) { return i }
        return nil
    }

    /// The lowest mic-stream region index not yet completed.
    public var nextMicRegionIndex: Int? {
        let done = Set(completedMicRegionIndices)
        for i in micRegions.indices where !done.contains(i) { return i }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobId = "job_id"
        case recordingId = "recording_id"
        case stage
        case systemRegions = "system_regions"
        case completedSystemRegionIndices = "completed_system_region_indices"
        case systemSegments = "system_segments"
        case micRegions = "mic_regions"
        case completedMicRegionIndices = "completed_mic_region_indices"
        case micSegments = "mic_segments"
        case language
        case lastCheckpointAt = "last_checkpoint_at"
        case lastError = "last_error"
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        var data = try e.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> RefinementProgress {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(RefinementProgress.self, from: data)
    }
}
