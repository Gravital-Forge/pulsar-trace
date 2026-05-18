import Foundation

/// One diarized speaker turn: a label active over `[start, end]` of the
/// recording.
///
/// `start`/`end` are offsets from the start of the **system-stream** recording
/// (R17 — only the system stream is diarized; the mic stream is always "You").
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

/// A speaker embedding from pyannote's pipeline (R29).
///
/// 256-dimensional in pyannote community-1. The embedding is in pyannote's own
/// vector space so it is directly comparable with the live pass and the
/// persistent speaker library — provided the `modelRevision` matches (the
/// speaker library refuses cross-checkpoint matches; Open Question #3).
public struct SpeakerEmbedding: Sendable, Equatable {
    /// Raw pyannote speaker label this embedding belongs to.
    public let speaker: String
    /// The embedding vector (256 floats for community-1).
    public let vector: [Float]

    public init(speaker: String, vector: [Float]) {
        self.speaker = speaker
        self.vector = vector
    }
}

/// The full result of an offline diarization run — the Swift decoding of the
/// JSON the Python `pulsartrace_ai.diarize` module emits.
public struct DiarizationResult: Sendable, Equatable {
    /// pyannote model identifier (`pyannote/speaker-diarization-community-1`).
    public let model: String
    /// Hugging Face hub commit SHA of the model *checkpoint*. This is the
    /// authoritative model identity — the speaker library refuses to
    /// match embeddings across a different `modelRevision` (Open Question #3).
    /// Empty when an older Python build produced the JSON.
    public let modelRevision: String
    /// pyannote.audio *library* version string. A secondary identity field —
    /// the library version is not a reliable proxy for checkpoint identity,
    /// so `modelRevision` is preferred for cross-match decisions.
    public let modelVersion: String
    /// Duration of the diarized WAV.
    public let audioDuration: Duration
    /// Raw pyannote speaker labels, sorted (`SPEAKER_00`, `SPEAKER_01`, …).
    public let speakers: [String]
    /// Speaker turns, overlap-preserving: when two speakers talk at once both
    /// attributions appear with overlapping time ranges.
    public let spans: [SpeakerSpan]
    /// Overlap-resolved turns — never two speakers active at the same instant.
    public let exclusiveSpans: [SpeakerSpan]
    /// Per-speaker embeddings (R29), keyed by raw pyannote label.
    public let embeddings: [SpeakerEmbedding]

    public init(
        model: String,
        modelRevision: String = "",
        modelVersion: String,
        audioDuration: Duration,
        speakers: [String],
        spans: [SpeakerSpan],
        exclusiveSpans: [SpeakerSpan],
        embeddings: [SpeakerEmbedding]
    ) {
        self.model = model
        self.modelRevision = modelRevision
        self.modelVersion = modelVersion
        self.audioDuration = audioDuration
        self.speakers = speakers
        self.spans = spans
        self.exclusiveSpans = exclusiveSpans
        self.embeddings = embeddings
    }

    /// The transcript-facing display label for a raw pyannote label.
    ///
    /// pyannote emits `SPEAKER_00`, `SPEAKER_01`, …; PulsarTrace's transcript
    /// format (R13 / `docs/file-format.md`) uses `Speaker_0`, `Speaker_1`, …
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
