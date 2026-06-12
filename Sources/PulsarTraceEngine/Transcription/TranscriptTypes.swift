import Foundation

/// A transcribed utterance: text plus its time span relative to recording start.
public struct TranscriptSegment: Sendable, Equatable {
    /// Offset from recording start to the segment's first sample.
    public let start: Duration
    /// Offset from recording start to the segment's last sample.
    public let end: Duration
    /// The recognized text, trimmed; never empty (blank segments are dropped).
    public let text: String

    public init(start: Duration, end: Duration, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Result of an offline transcription run.
public struct TranscriptionResult: Sendable, Equatable {
    /// The non-blank utterances, in time order.
    public let segments: [TranscriptSegment]
    /// The language whisper detected/used (ISO-639-1, e.g. `en`).
    public let language: String

    public init(segments: [TranscriptSegment], language: String) {
        self.segments = segments
        self.language = language
    }
}

/// A contiguous span of detected voice activity in a recording, in
/// recording-relative time.
///
/// Produced by `WhisperTranscriber.detectSpeechRegions(in:vadModelURL:…)` and
/// consumed by `transcribe(_:regions:options:)`, which decodes each region
/// independently so the offline transcript breaks at conversational turn
/// pauses instead of emitting one long segment that the time-order merge would
/// float ahead of an interleaved speaker.
public struct SpeechRegion: Sendable, Equatable {
    /// Offset from recording start to the region's first sample.
    public let start: Duration
    /// Offset from recording start to the region's last sample.
    public let end: Duration

    public init(start: Duration, end: Duration) {
        self.start = start
        self.end = end
    }
}

extension SpeechRegion {
    /// Merge speech regions separated by less than `minGap` so the transcript
    /// breaks at genuine turn pauses, not at every short breath. `regions` must
    /// be in ascending start order; the result is too.
    static func coalesced(
        _ regions: [SpeechRegion],
        minGap: Duration
    ) -> [SpeechRegion] {
        guard var current = regions.first else { return [] }
        var out: [SpeechRegion] = []
        for region in regions.dropFirst() {
            if region.start - current.end < minGap {
                current = SpeechRegion(
                    start: current.start,
                    end: max(current.end, region.end))
            } else {
                out.append(current)
                current = region
            }
        }
        out.append(current)
        return out
    }
}
