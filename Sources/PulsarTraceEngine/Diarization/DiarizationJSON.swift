import Foundation

/// Codable mirror of the JSON the Python `pulsartrace_ai.diarize` module emits.
///
/// This is the wire format of the Swift↔Python diarization contract. The
/// `schema` field is an integer the Python side bumps on a breaking change;
/// `DiarizationDecoder` rejects an unrecognised schema rather than silently
/// mis-decoding.
///
/// Contract (see `python/pulsartrace-ai/pulsartrace_ai/diarize.py`):
/// ```json
/// {
///   "schema": 1,
///   "model": "pyannote/speaker-diarization-community-1",
///   "model_revision": "<HF hub commit SHA of the model checkpoint>",
///   "model_version": "4.0.4",
///   "audio_duration": 24.0,
///   "speakers": ["SPEAKER_00", "SPEAKER_01"],
///   "spans": [{"speaker": "SPEAKER_00", "start": 0.031, "end": 8.452}],
///   "exclusive_spans": [ ... ],
///   "embeddings": {"SPEAKER_00": [0.1, ...]},
///   "embedding_dim": 256
/// }
/// ```
struct DiarizationPayload: Decodable {
    /// Schema versions this Swift build can decode.
    static let supportedSchema = 1

    struct Span: Decodable {
        let speaker: String
        let start: Double
        let end: Double
    }

    let schema: Int
    let model: String
    /// Hugging Face hub commit SHA of the model checkpoint. Optional so a JSON
    /// blob from an older Python build (which only carried `model_version`)
    /// still decodes — schema stays 1 because this is an additive field.
    let modelRevision: String?
    let modelVersion: String
    let audioDuration: Double
    let speakers: [String]
    let spans: [Span]
    let exclusiveSpans: [Span]
    let embeddings: [String: [Double]]
    let embeddingDim: Int

    enum CodingKeys: String, CodingKey {
        case schema
        case model
        case modelRevision = "model_revision"
        case modelVersion = "model_version"
        case audioDuration = "audio_duration"
        case speakers
        case spans
        case exclusiveSpans = "exclusive_spans"
        case embeddings
        case embeddingDim = "embedding_dim"
    }
}

/// Decodes the Python diarization JSON into the engine's `DiarizationResult`.
enum DiarizationDecoder {

    enum DecodeError: Error, CustomStringConvertible, Equatable {
        case malformedJSON(String)
        case unsupportedSchema(found: Int, supported: Int)

        var description: String {
            switch self {
            case .malformedJSON(let detail):
                return "diarization JSON could not be decoded: \(detail)"
            case .unsupportedSchema(let found, let supported):
                return "diarization JSON schema \(found) unsupported "
                    + "(this build decodes schema \(supported))"
            }
        }
    }

    /// Decode a raw JSON `Data` blob from the Python subprocess.
    static func decode(_ data: Data) throws -> DiarizationResult {
        let payload: DiarizationPayload
        do {
            payload = try JSONDecoder().decode(DiarizationPayload.self, from: data)
        } catch {
            throw DecodeError.malformedJSON(String(describing: error))
        }

        guard payload.schema == DiarizationPayload.supportedSchema else {
            throw DecodeError.unsupportedSchema(
                found: payload.schema,
                supported: DiarizationPayload.supportedSchema
            )
        }

        return DiarizationResult(
            model: payload.model,
            modelRevision: payload.modelRevision ?? "",
            audioDuration: durationFromSeconds(payload.audioDuration),
            speakers: payload.speakers,
            spans: payload.spans.map(span(from:)),
            embeddings: payload.embeddings
                .map { SpeakerEmbedding(speaker: $0.key, vector: $0.value.map(Float.init)) }
                .sorted { $0.speaker < $1.speaker }
        )
    }

    private static func span(from raw: DiarizationPayload.Span) -> SpeakerSpan {
        SpeakerSpan(
            speaker: raw.speaker,
            start: durationFromSeconds(raw.start),
            end: durationFromSeconds(raw.end)
        )
    }

    /// Convert a fractional-seconds `Double` to a `Duration` at millisecond
    /// precision — enough for diarization spans and keeps `Duration` exact.
    private static func durationFromSeconds(_ seconds: Double) -> Duration {
        .milliseconds(Int((seconds * 1000).rounded()))
    }
}
