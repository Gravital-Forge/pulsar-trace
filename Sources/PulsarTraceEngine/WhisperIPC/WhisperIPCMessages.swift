import Foundation

// MARK: - Request

/// One request to the whisper subprocess. Lives in `PulsarTraceEngine` so the
/// parent-side client (Phase 3) and the `pulsartrace-whisper` binary share
/// the same Codable definition — no risk of the two ends drifting.
///
/// JSON shape: `{ "type": "<case>", … case-specific fields }`. The
/// `"type"` discriminator is a single string so the wire format is
/// human-readable in logs / `tcpdump -X`, and so adding a new case is
/// purely additive (older consumers reject unknown types with a Decoder
/// error rather than silently mis-decoding).
public enum WhisperIPCRequest: Sendable, Codable, Equatable {
    /// Sent once after connect, before any decode request. The subprocess
    /// loads the model and replies with `.ready`.
    case initSession(model: String, gpu: Bool)
    /// One streaming-window decode. Returns `.decoded`.
    case decodeWindow(WhisperIPCDecodeWindow)
    /// One refinement-region decode. Returns `.decoded`.
    case decodeRegion(WhisperIPCDecodeRegion)
    /// Graceful exit — the subprocess closes its connection and exits 0.
    /// SIGTERM is the equivalent fallback (spec §5).
    case shutdown

    private enum DiscriminatorKey: String, CodingKey { case type }
    private enum CaseKey: String {
        case initSession = "init"
        case decodeWindow = "decode_window"
        case decodeRegion = "decode_region"
        case shutdown
    }
    private enum InitKeys: String, CodingKey {
        case type, model, gpu
    }
    private enum DecodeWindowKeys: String, CodingKey {
        case type, payload
    }
    private enum DecodeRegionKeys: String, CodingKey {
        case type, payload
    }
    private enum ShutdownKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: DiscriminatorKey.self)
        // Decode the discriminator as a plain String so an unknown value
        // surfaces as a descriptive `dataCorruptedError` rather than the
        // raw-value Codable's "Cannot initialize CaseKey from invalid
        // String value …" — the former tells the caller which key was bad
        // and what came in on the wire.
        let rawType = try typeContainer.decode(String.self, forKey: .type)
        guard let caseKey = CaseKey(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: DiscriminatorKey.type,
                in: typeContainer,
                debugDescription: "unknown whisper IPC request type: \"\(rawType)\"")
        }
        switch caseKey {
        case .initSession:
            let c = try decoder.container(keyedBy: InitKeys.self)
            self = .initSession(
                model: try c.decode(String.self, forKey: .model),
                gpu: try c.decode(Bool.self, forKey: .gpu))
        case .decodeWindow:
            let c = try decoder.container(keyedBy: DecodeWindowKeys.self)
            self = .decodeWindow(
                try c.decode(WhisperIPCDecodeWindow.self, forKey: .payload))
        case .decodeRegion:
            let c = try decoder.container(keyedBy: DecodeRegionKeys.self)
            self = .decodeRegion(
                try c.decode(WhisperIPCDecodeRegion.self, forKey: .payload))
        case .shutdown:
            self = .shutdown
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .initSession(let model, let gpu):
            var c = encoder.container(keyedBy: InitKeys.self)
            try c.encode(CaseKey.initSession.rawValue, forKey: .type)
            try c.encode(model, forKey: .model)
            try c.encode(gpu, forKey: .gpu)
        case .decodeWindow(let p):
            var c = encoder.container(keyedBy: DecodeWindowKeys.self)
            try c.encode(CaseKey.decodeWindow.rawValue, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .decodeRegion(let p):
            var c = encoder.container(keyedBy: DecodeRegionKeys.self)
            try c.encode(CaseKey.decodeRegion.rawValue, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .shutdown:
            var c = encoder.container(keyedBy: ShutdownKeys.self)
            try c.encode(CaseKey.shutdown.rawValue, forKey: .type)
        }
    }
}

/// A `decodeWindow` request body. `samplesBase64` is the window samples,
/// 16 kHz mono Float32 little-endian, base64-encoded — same byte order as
/// the capture channel's PCM payload (`FrameProtocol`). `windowStartMs` is
/// added to whisper segment times so the response carries
/// recording-absolute timestamps, matching the in-process
/// `WhisperTranscriber.transcribeWindow` contract.
public struct WhisperIPCDecodeWindow: Sendable, Codable, Equatable {
    public let requestId: UUID
    public let samplesBase64: String
    public let windowStartMs: Int64
    public let options: WhisperIPCOptions

    public init(
        requestId: UUID,
        samplesBase64: String,
        windowStartMs: Int64,
        options: WhisperIPCOptions
    ) {
        self.requestId = requestId
        self.samplesBase64 = samplesBase64
        self.windowStartMs = windowStartMs
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case samplesBase64 = "samples_base64"
        case windowStartMs = "window_start_ms"
        case options
    }
}

/// A `decodeRegion` request body. Mirrors the in-process
/// `WhisperTranscriber.transcribeRegion` shape: the *whole* recording's
/// samples plus a `[regionStartMs, regionEndMs)` window into them. The
/// subprocess slices and shifts internally so the response timestamps come
/// back recording-absolute.
public struct WhisperIPCDecodeRegion: Sendable, Codable, Equatable {
    public let requestId: UUID
    public let samplesBase64: String
    public let regionStartMs: Int64
    public let regionEndMs: Int64
    public let options: WhisperIPCOptions

    public init(
        requestId: UUID,
        samplesBase64: String,
        regionStartMs: Int64,
        regionEndMs: Int64,
        options: WhisperIPCOptions
    ) {
        self.requestId = requestId
        self.samplesBase64 = samplesBase64
        self.regionStartMs = regionStartMs
        self.regionEndMs = regionEndMs
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case samplesBase64 = "samples_base64"
        case regionStartMs = "region_start_ms"
        case regionEndMs = "region_end_ms"
        case options
    }
}

/// Codable mirror of `WhisperOptions`. The in-process type's `vadModelURL`
/// is `URL?`, which doesn't round-trip through JSON cleanly (file URLs grow
/// host/scheme noise); we send a plain filesystem `String?` instead. The
/// defaults match `WhisperOptions.init`.
public struct WhisperIPCOptions: Sendable, Codable, Equatable {
    public var language: String?
    public var allowedLanguages: [String]
    public var threadCount: Int
    public var noSpeechThreshold: Float
    public var temperature: Float
    public var temperatureFallbackStep: Float
    public var vadModelPath: String?

    public init(
        language: String? = nil,
        allowedLanguages: [String] = [],
        threadCount: Int = 1,
        noSpeechThreshold: Float = 0.6,
        temperature: Float = 0.2,
        temperatureFallbackStep: Float = 0.2,
        vadModelPath: String? = nil
    ) {
        self.language = language
        self.allowedLanguages = allowedLanguages
        self.threadCount = threadCount
        self.noSpeechThreshold = noSpeechThreshold
        self.temperature = temperature
        self.temperatureFallbackStep = temperatureFallbackStep
        self.vadModelPath = vadModelPath
    }

    /// Convert from the in-process options. URL → path-string lossy step:
    /// `URL.path` is what the subprocess needs anyway to call
    /// `whisper_vad_init_from_file_with_params`.
    public init(from options: WhisperOptions) {
        self.language = options.language
        self.allowedLanguages = options.allowedLanguages
        self.threadCount = options.threadCount
        self.noSpeechThreshold = options.noSpeechThreshold
        self.temperature = options.temperature
        self.temperatureFallbackStep = options.temperatureFallbackStep
        self.vadModelPath = options.vadModelURL?.path
    }

    /// Convert back to the in-process options. `vadModelPath` becomes a
    /// `URL(fileURLWithPath:)`; round-tripping a `URL` through this struct
    /// is lossy on host/scheme but preserves the on-disk path.
    public func toWhisperOptions() -> WhisperOptions {
        WhisperOptions(
            language: language,
            allowedLanguages: allowedLanguages,
            threadCount: threadCount,
            noSpeechThreshold: noSpeechThreshold,
            temperature: temperature,
            temperatureFallbackStep: temperatureFallbackStep,
            vadModelURL: vadModelPath.map { URL(fileURLWithPath: $0) })
    }

    /// Older peers (no `allowedLanguages` field) decode as empty, preserving
    /// the unrestricted-auto-detect default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.allowedLanguages = try c.decodeIfPresent(
            [String].self, forKey: .allowedLanguages) ?? []
        self.threadCount = try c.decode(Int.self, forKey: .threadCount)
        self.noSpeechThreshold = try c.decode(
            Float.self, forKey: .noSpeechThreshold)
        self.temperature = try c.decode(Float.self, forKey: .temperature)
        self.temperatureFallbackStep = try c.decode(
            Float.self, forKey: .temperatureFallbackStep)
        self.vadModelPath = try c.decodeIfPresent(
            String.self, forKey: .vadModelPath)
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case allowedLanguages = "allowed_languages"
        case threadCount = "thread_count"
        case noSpeechThreshold = "no_speech_threshold"
        case temperature
        case temperatureFallbackStep = "temperature_fallback_step"
        case vadModelPath = "vad_model_path"
    }
}

// MARK: - Response

/// One response from the whisper subprocess. Like `WhisperIPCRequest`, the
/// JSON discriminator is `"type"` so a future case is purely additive.
public enum WhisperIPCResponse: Sendable, Codable, Equatable {
    /// Ack to `.initSession` — the model loaded successfully.
    case ready(modelLoadMs: Int)
    /// Decoded segments for a `decodeWindow` / `decodeRegion` request.
    case decoded(WhisperIPCDecoded)
    /// A failure tied to a specific request (`requestId` set) or a session
    /// failure (`requestId == nil`, e.g. model load failed).
    case error(WhisperIPCError)

    private enum DiscriminatorKey: String, CodingKey { case type }
    private enum CaseKey: String {
        case ready
        case decoded
        case error
    }
    private enum ReadyKeys: String, CodingKey {
        case type
        case modelLoadMs = "model_load_ms"
    }
    private enum DecodedKeys: String, CodingKey {
        case type, payload
    }
    private enum ErrorKeys: String, CodingKey {
        case type, payload
    }

    public init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: DiscriminatorKey.self)
        let rawType = try typeContainer.decode(String.self, forKey: .type)
        guard let caseKey = CaseKey(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: DiscriminatorKey.type,
                in: typeContainer,
                debugDescription: "unknown whisper IPC response type: \"\(rawType)\"")
        }
        switch caseKey {
        case .ready:
            let c = try decoder.container(keyedBy: ReadyKeys.self)
            self = .ready(modelLoadMs: try c.decode(Int.self, forKey: .modelLoadMs))
        case .decoded:
            let c = try decoder.container(keyedBy: DecodedKeys.self)
            self = .decoded(try c.decode(WhisperIPCDecoded.self, forKey: .payload))
        case .error:
            let c = try decoder.container(keyedBy: ErrorKeys.self)
            self = .error(try c.decode(WhisperIPCError.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .ready(let ms):
            var c = encoder.container(keyedBy: ReadyKeys.self)
            try c.encode(CaseKey.ready.rawValue, forKey: .type)
            try c.encode(ms, forKey: .modelLoadMs)
        case .decoded(let p):
            var c = encoder.container(keyedBy: DecodedKeys.self)
            try c.encode(CaseKey.decoded.rawValue, forKey: .type)
            try c.encode(p, forKey: .payload)
        case .error(let p):
            var c = encoder.container(keyedBy: ErrorKeys.self)
            try c.encode(CaseKey.error.rawValue, forKey: .type)
            try c.encode(p, forKey: .payload)
        }
    }
}

/// A `.decoded` response body — the segments produced for one decode
/// request, in recording-absolute time. No token-level detail for now:
/// `TranscriptSegment` doesn't carry tokens, and the live committer +
/// refinement pipeline don't need them. Spec §10 flags adding them if a
/// future consumer needs token probabilities or per-token timing.
public struct WhisperIPCDecoded: Sendable, Codable, Equatable {
    public let requestId: UUID
    public let segments: [WhisperIPCSegment]
    public let language: String

    public init(requestId: UUID, segments: [WhisperIPCSegment], language: String) {
        self.requestId = requestId
        self.segments = segments
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case segments
        case language
    }
}

/// One transcript segment. `start`/`end` are integer milliseconds —
/// `TranscriptSegment.start` is a `Duration`, which has no obvious JSON
/// shape; ms keeps timestamps inside `Int64` for the full recording
/// length and round-trips losslessly to whisper's 10 ms timestamp grid.
public struct WhisperIPCSegment: Sendable, Codable, Equatable {
    public let text: String
    public let startMs: Int64
    public let endMs: Int64

    public init(text: String, startMs: Int64, endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

/// A `.error` response body. `requestId` is `nil` for session-scope
/// failures (model load, lifecycle); otherwise it identifies the request
/// that failed so a parent client can correlate.
///
/// `kind` is a stable string ("model_not_found" | "model_load_failed" |
/// "transcription_failed" | "empty_audio" | "decode_internal" |
/// "init_twice") so callers can branch on a typo-resistant key without
/// parsing `message`. The subprocess emits "decode_internal" for any
/// non-`WhisperTranscribeError` thrown from the decode call.
public struct WhisperIPCError: Sendable, Codable, Equatable {
    public let requestId: UUID?
    public let kind: String
    public let message: String

    public init(requestId: UUID? = nil, kind: String, message: String) {
        self.requestId = requestId
        self.kind = kind
        self.message = message
    }

    /// Convert from the lifted in-process error type so the subprocess can
    /// forward whisper failures with the same kinds the parent expects.
    public init(from error: WhisperTranscribeError, requestId: UUID? = nil) {
        self.requestId = requestId
        switch error {
        case .modelNotFound:
            self.kind = "model_not_found"
        case .modelLoadFailed:
            self.kind = "model_load_failed"
        case .transcriptionFailed:
            self.kind = "transcription_failed"
        case .emptyAudio:
            self.kind = "empty_audio"
        }
        self.message = error.description
    }

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case kind
        case message
    }
}

// MARK: - Samples (Float32 LE ↔ base64)

/// Sample-payload encoding helpers. The samples on the wire are 16 kHz mono
/// Float32 *little-endian*, matching the capture protocol's byte order, so
/// the same byte sequence flows in and out of the subprocess with no
/// re-ordering on either side (Apple silicon, our deploy target, is also
/// little-endian).
public enum WhisperIPCSamples {

    /// Encode an array of `Float` samples as base64'd little-endian Float32
    /// bytes. A 30 s window is ~480 000 samples ≈ 1.9 MB → ~2.6 MB base64,
    /// well under `WhisperFrameCodec.maxPayloadBytes`.
    public static func encode(_ samples: [Float]) -> String {
        var bytes = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            var le = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        }
        return bytes.base64EncodedString()
    }

    public enum SampleError: Error, CustomStringConvertible, Equatable {
        case invalidBase64
        case payloadNotFloatAligned(Int)

        public var description: String {
            switch self {
            case .invalidBase64:
                return "whisper IPC samples: invalid base64"
            case .payloadNotFloatAligned(let n):
                return "whisper IPC samples: \(n) bytes not Float32-aligned"
            }
        }
    }

    /// Decode a base64'd little-endian Float32 sample payload. Throws
    /// `.invalidBase64` on malformed input, `.payloadNotFloatAligned` if
    /// the decoded byte count isn't a multiple of 4.
    public static func decode(_ base64: String) throws -> [Float] {
        guard let bytes = Data(base64Encoded: base64) else {
            throw SampleError.invalidBase64
        }
        guard bytes.count % MemoryLayout<Float>.size == 0 else {
            throw SampleError.payloadNotFloatAligned(bytes.count)
        }
        let count = bytes.count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: count)
        if count > 0 {
            _ = out.withUnsafeMutableBytes { dst in
                bytes.copyBytes(to: dst.bindMemory(to: UInt8.self))
            }
            // Normalize from little-endian on a little-endian host this is a
            // no-op; keep the call explicit for portability.
            out = out.map { sample in
                Float(bitPattern: UInt32(littleEndian: sample.bitPattern))
            }
        }
        return out
    }
}
