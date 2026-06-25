import Foundation
@testable import PulsarTraceEngine

/// Decodes the committed diarization JSON fixtures
/// (`Tests/Fixtures/diarization/*.json`) into a `DiarizationResult`.
///
/// These files were captured from the retired Python pyannote pipeline (D40).
/// They are no longer a wire contract — just frozen, realistic test data for
/// the merge / reconciliation logic, which is embedding-space-agnostic.
/// Unknown keys in the files (`schema`, `model_version`, `exclusive_spans`,
/// `embedding_dim`) are deliberately ignored.
enum DiarizationFixtureDecoder {

    private struct Payload: Decodable {
        struct Span: Decodable {
            let speaker: String
            let start: Double
            let end: Double
        }
        let model: String
        let modelRevision: String?
        let audioDuration: Double
        let speakers: [String]
        let spans: [Span]
        let embeddings: [String: [Double]]

        enum CodingKeys: String, CodingKey {
            case model
            case modelRevision = "model_revision"
            case audioDuration = "audio_duration"
            case speakers
            case spans
            case embeddings
        }
    }

    static func decode(_ data: Data) throws -> DiarizationResult {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return DiarizationResult(
            model: payload.model,
            modelRevision: payload.modelRevision ?? "",
            audioDuration: .milliseconds(Int((payload.audioDuration * 1000).rounded())),
            speakers: payload.speakers,
            spans: payload.spans.map {
                SpeakerSpan(
                    speaker: $0.speaker,
                    start: .milliseconds(Int(($0.start * 1000).rounded())),
                    end: .milliseconds(Int(($0.end * 1000).rounded())))
            },
            embeddings: payload.embeddings
                .map { SpeakerEmbedding(speaker: $0.key, vector: $0.value.map(Float.init)) }
                .sorted { $0.speaker < $1.speaker })
    }
}
