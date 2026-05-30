import Foundation

/// Tunables for a transcription run. The defaults target the offline
/// refine pass; production may raise `threadCount`.
///
/// Lifted out of `WhisperTranscriber` so the same value type can be passed
/// to an in-process transcriber, a test double, or a future remote (IPC)
/// transcriber without depending on the in-process whisper class.
public struct WhisperOptions: Sendable, Equatable {
    /// `nil` → auto-detect (whisper picks the language). A two-letter code
    /// forces that language. The default multilingual `base`/`large-v3`
    /// models support auto-detect.
    public var language: String?
    /// Decoder threads. 1 keeps output deterministic and is plenty for the
    /// offline path on a fixture; bump for large recordings.
    public var threadCount: Int
    /// whisper's no-speech threshold — segments above this probability of
    /// being non-speech are dropped by whisper before they reach us. Guards
    /// against silence hallucinations ("thanks for watching").
    public var noSpeechThreshold: Float
    /// Decoder temperature for the *first* decode pass. whisper.cpp samples
    /// the token distribution when this is > 0; its sampler RNG is seeded
    /// with a fixed constant per `whisper_full` call, so a non-zero value
    /// is still byte-reproducible run-to-run on a given build. `0` is pure
    /// argmax. Read by `transcribe(_:)` only — `transcribeWindow` keeps
    /// argmax for committer stability.
    public var temperature: Float
    /// Temperature step for whisper's fallback re-decode. When a segment
    /// fails whisper's quality checks (compression-ratio / avg-logprob /
    /// no-speech), whisper retries it at `temperature + step`, then
    /// `+ 2·step`, … up to 1.0. This is whisper's primary escape from a
    /// degenerate greedy-decode loop: at `0` a failed window has no
    /// fallback and its garbage tokens poison every later window in the
    /// same call. Read by `transcribe(_:)` only.
    public var temperatureFallbackStep: Float
    /// Path to a ggml Silero VAD model. When set, `transcribe(_:)` enables
    /// whisper.cpp's built-in voice-activity detection: non-speech regions
    /// are dropped before decoding, so a long digital-silence stretch in a
    /// recording can't drive the decoder into a degenerate state. `nil`
    /// disables VAD (whole-buffer decode). Ignored by `transcribeWindow`,
    /// which the streaming pipeline already VAD-gates upstream.
    public var vadModelURL: URL?

    public init(
        language: String? = nil,
        threadCount: Int = 1,
        noSpeechThreshold: Float = 0.6,
        temperature: Float = 0.2,
        temperatureFallbackStep: Float = 0.2,
        vadModelURL: URL? = nil
    ) {
        self.language = language
        self.threadCount = threadCount
        self.noSpeechThreshold = noSpeechThreshold
        self.temperature = temperature
        self.temperatureFallbackStep = temperatureFallbackStep
        self.vadModelURL = vadModelURL
    }

    /// Default GPU setting, resolved from the environment.
    ///
    /// `PULSARTRACE_WHISPER_CPU` set to `1`/`true`/`yes` forces whisper's CPU
    /// backend process-wide. This is the escape hatch for hosts where the Metal
    /// GPU is unreachable — notably a command sandbox that denies IOKit GPU
    /// access, where the Metal backend crashes during buffer allocation. The
    /// production default is GPU (Metal).
    public static var defaultGPUEnabled: Bool {
        switch ProcessInfo.processInfo.environment["PULSARTRACE_WHISPER_CPU"]?
            .lowercased()
        {
        case "1", "true", "yes": return false
        default: return true
        }
    }
}

/// Errors thrown by whisper transcription paths (in-process or remote).
///
/// Lifted out of `WhisperTranscriber` so a remote (IPC) transcriber and test
/// doubles can throw the same shape without depending on the in-process class.
public enum WhisperTranscribeError: Error, CustomStringConvertible, Equatable {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case transcriptionFailed(Int)
    case emptyAudio

    public var description: String {
        switch self {
        case .modelNotFound(let p): return "whisper model not found: \(p)"
        case .modelLoadFailed(let p): return "whisper model failed to load: \(p)"
        case .transcriptionFailed(let c): return "whisper_full failed with code \(c)"
        case .emptyAudio: return "no audio samples to transcribe"
        }
    }
}
