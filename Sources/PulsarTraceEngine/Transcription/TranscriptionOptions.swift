import Foundation

/// Tunables for a transcription run, shared by the live (Parakeet) and
/// refine (WhisperKit) passes — the option carrier through every seam
/// (`WindowTranscribing`, `ResumableRefiner`, `RefinementTranscriber`).
public struct TranscriptionOptions: Sendable, Equatable {
    /// `nil` → auto-detect / allowed-languages policy. A two-letter
    /// ISO-639-1 code hard-pins the refine decode (`refine --language`,
    /// `WhisperKitLanguagePolicy` rule 1). The live pass ignores it —
    /// Parakeet has no language pinning.
    public var language: String?
    /// Optional allow-list of ISO-639-1 codes (the Settings "Restrict to
    /// languages" selector). Live: exactly one code becomes FluidAudio's
    /// script hint (`ParakeetEngine.languageHint`). Refine: one code pins;
    /// several → per-region detect-among (`WhisperKitLanguagePolicy`).
    public var allowedLanguages: [String]
    /// The no-speech threshold — segments above this probability of being
    /// non-speech are dropped by the decoder before they reach us. Guards
    /// against silence hallucinations ("thanks for watching").
    public var noSpeechThreshold: Float

    public init(
        language: String? = nil,
        allowedLanguages: [String] = [],
        noSpeechThreshold: Float = 0.6
    ) {
        self.language = language
        self.allowedLanguages = allowedLanguages
        self.noSpeechThreshold = noSpeechThreshold
    }
}

/// Errors thrown by transcription paths (live or refine) and test doubles.
/// (Previously `WhisperTranscribeError`; same cases — `RefinementJobError.
/// classify` and `ResumableRefiner.transcribeRegionWithRetry` key off them.)
public enum TranscriptionError: Error, CustomStringConvertible, Equatable {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case transcriptionFailed(Int)
    case emptyAudio
    /// A window decode exceeded its wall-clock deadline and was abandoned
    /// (ANE/CoreML decodes cannot be cancelled mid-predict).
    case decodeDeadlineExceeded

    public var description: String {
        switch self {
        case .modelNotFound(let p): return "model not found: \(p)"
        case .modelLoadFailed(let p): return "model failed to load: \(p)"
        case .transcriptionFailed(let c): return "transcription failed with code \(c)"
        case .emptyAudio: return "no audio samples to transcribe"
        case .decodeDeadlineExceeded:
            return "window decode exceeded its deadline — decoder abandoned"
        }
    }
}
