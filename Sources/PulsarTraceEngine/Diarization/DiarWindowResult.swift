import Foundation

/// The raw, window-local diarization output for one window — the flat result
/// shape `DiarizerEngineRawAdapter` returns in-process and `LiveDiarizer`
/// stitches. Times are window-local milliseconds (the stitcher adds the
/// recording-absolute `windowStart`). Deliberately a flat DTO (not the engine's
/// `DiarizationResult`) so the live stitching seam stays narrow and trivially
/// testable.
public struct DiarWindowResult: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        public let speaker: String       // raw per-window label, e.g. "S1"
        public let startMillis: Int
        public let endMillis: Int
        public init(speaker: String, startMillis: Int, endMillis: Int) {
            self.speaker = speaker
            self.startMillis = startMillis
            self.endMillis = endMillis
        }
    }
    public struct Embedding: Sendable, Equatable {
        public let speaker: String       // matches Span.speaker
        public let vector: [Float]       // 256-d WeSpeaker; empty if none
        public init(speaker: String, vector: [Float]) {
            self.speaker = speaker
            self.vector = vector
        }
    }
    public let spans: [Span]
    public let embeddings: [Embedding]
    public init(spans: [Span], embeddings: [Embedding]) {
        self.spans = spans
        self.embeddings = embeddings
    }
}
