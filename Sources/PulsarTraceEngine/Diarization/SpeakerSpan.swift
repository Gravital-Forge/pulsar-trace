import Foundation

/// One diarized speaker turn: a label active over `[start, end]` of the
/// recording.
///
/// `start`/`end` are offsets from the start of the **system-stream** recording
/// (PT-R17 — only the system stream is diarized; the mic stream is always "You").
/// pyannote's raw labels are `SPEAKER_00`, `SPEAKER_01`, … — PulsarTrace
/// re-renders them as `Speaker_0`, `Speaker_1`, … for the transcript
/// (see `DiarizationResult.displayLabel(for:)`).
public struct SpeakerSpan: Sendable, Equatable {
    /// Raw pyannote speaker label, e.g. `SPEAKER_00`.
    public let speaker: String
    /// Offset from recording start to the turn's first sample.
    public let start: Duration
    /// Offset from recording start to the turn's last sample.
    public let end: Duration

    public init(speaker: String, start: Duration, end: Duration) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    /// Length of the overlap between this span and `range`, in seconds.
    /// Zero when they do not intersect. Used to attribute an utterance to the
    /// speaker it overlaps most.
    func overlapSeconds(with range: ClosedRange<Double>) -> Double {
        let lo = max(start.seconds, range.lowerBound)
        let hi = min(end.seconds, range.upperBound)
        return max(0, hi - lo)
    }
}

/// A 256-d speaker embedding from the diarization backend's embedding model
/// (PT-R112).
///
/// The embedding is in the backend's own vector space so it is directly
/// comparable with the live pass and the persistent speaker library — but only
/// within one `modelRevision` (the speaker library refuses cross-checkpoint
/// matches; Open Question #3).
public struct SpeakerEmbedding: Sendable, Equatable {
    /// Raw pyannote speaker label this embedding belongs to.
    public let speaker: String
    /// The embedding vector (256 floats).
    public let vector: [Float]

    public init(speaker: String, vector: [Float]) {
        self.speaker = speaker
        self.vector = vector
    }
}

/// The full result of an offline diarization run — produced in-process by
/// `DiarizationResultMapper` from FluidAudio's CoreML/ANE pipeline (PT-P5-D3).
public struct DiarizationResult: Sendable, Equatable {
    /// Diarization model identifier
    /// (`FluidInference/speaker-diarization-coreml`).
    public let model: String
    /// Content digest (DirectoryDigest SHA-256) of the model directory. This
    /// is the authoritative model identity — the speaker library refuses to
    /// match embeddings across a different `modelRevision` (Open Question #3
    /// / PT-P5-D3). Empty only in frozen test fixtures predating the digest.
    public let modelRevision: String
    /// Duration of the diarized WAV.
    public let audioDuration: Duration
    /// Raw per-run speaker labels, natural-sorted (`S1`, `S2`, …).
    public let speakers: [String]
    /// Speaker turns, overlap-preserving: when two speakers talk at once both
    /// attributions appear with overlapping time ranges.
    public let spans: [SpeakerSpan]
    /// Per-speaker embeddings (PT-R112), keyed by raw speaker label.
    public let embeddings: [SpeakerEmbedding]

    public init(
        model: String,
        modelRevision: String = "",
        audioDuration: Duration,
        speakers: [String],
        spans: [SpeakerSpan],
        embeddings: [SpeakerEmbedding]
    ) {
        self.model = model
        self.modelRevision = modelRevision
        self.audioDuration = audioDuration
        self.speakers = speakers
        self.spans = spans
        self.embeddings = embeddings
    }

    /// The transcript-facing display label for a raw pyannote label.
    ///
    /// pyannote emits `SPEAKER_00`, `SPEAKER_01`, …; PulsarTrace's transcript
    /// format (PT-R13 / `docs/file-format.md`) uses `Speaker_0`, `Speaker_1`, …
    /// The mapping is positional over the sorted `speakers` list, so it is
    /// stable for a given diarization result. An unknown label falls back to
    /// itself so a merge never silently drops text.
    public func displayLabel(for rawSpeaker: String) -> String {
        if let index = speakers.firstIndex(of: rawSpeaker) {
            return "Speaker_\(index)"
        }
        return rawSpeaker
    }
}

extension Duration {
    /// This duration as a `Double` count of seconds.
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
