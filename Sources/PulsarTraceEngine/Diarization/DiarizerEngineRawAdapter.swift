import Foundation

/// Adapts the in-process FluidAudio `DiarizerEngine` to `RawWindowDiarizing`,
/// converting its `DiarizationResult` to the flat wire DTO. Used inside the
/// diarizer worker process (D43), and as the in-process conformer for tests.
public struct DiarizerEngineRawAdapter: RawWindowDiarizing {
    private let engine: DiarizerEngine
    public init(engine: DiarizerEngine) { self.engine = engine }

    public func diarizeRawWindow(samples: [Float]) async -> DiarWindowResult? {
        guard let result = try? await engine.diarize(samples: samples) else { return nil }
        let spans = result.spans.map {
            DiarWindowResult.Span(
                speaker: $0.speaker,
                startMillis: $0.start.milliseconds,
                endMillis: $0.end.milliseconds)
        }
        let embeddings = result.embeddings.map {
            DiarWindowResult.Embedding(speaker: $0.speaker, vector: $0.vector)
        }
        return DiarWindowResult(spans: spans, embeddings: embeddings)
    }

    public func modelRevision() async -> String { engine.modelRevision }
}

extension Duration {
    /// Whole milliseconds (truncating). Used to flatten span times for the wire.
    var milliseconds: Int {
        let c = components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
