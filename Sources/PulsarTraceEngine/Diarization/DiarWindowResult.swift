import Foundation

/// The raw, window-local diarization output for one window — the only payload
/// the stateless diarizer worker returns. Times are window-local milliseconds
/// (the engine-side stitcher adds the recording-absolute `windowStart`).
/// Deliberately a flat `Codable` DTO (not the engine's `DiarizationResult`,
/// which is not `Codable`) so it crosses the worker socket as JSON.
public struct DiarWindowResult: Codable, Sendable, Equatable {
    public struct Span: Codable, Sendable, Equatable {
        public let speaker: String       // raw per-window label, e.g. "S1"
        public let startMillis: Int
        public let endMillis: Int
        public init(speaker: String, startMillis: Int, endMillis: Int) {
            self.speaker = speaker
            self.startMillis = startMillis
            self.endMillis = endMillis
        }
    }
    public struct Embedding: Codable, Sendable, Equatable {
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

    public static let empty = DiarWindowResult(spans: [], embeddings: [])
}

/// Worker → engine messages. `hello` is sent once on connect (carrying the
/// model digest the engine needs for the R18 library lookup); `result` carries
/// one window's output, correlated to a request by `requestId`.
public enum DiarWorkerMessage: Codable, Sendable, Equatable {
    case hello(modelRevision: String)
    case result(requestId: UInt64, window: DiarWindowResult)
}
