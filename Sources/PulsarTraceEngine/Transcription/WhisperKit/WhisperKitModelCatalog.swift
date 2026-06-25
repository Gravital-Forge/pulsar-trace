import Foundation

/// A WhisperKit CoreML model variant the refine pass can load.
///
/// `name` is the PulsarTrace-facing string (settings / `refine --model` /
/// `record --refine-model`); `variant` is the folder name inside the
/// `argmaxinc/whisperkit-coreml` Hugging Face repo. No pinned SHA-256:
/// WhisperKit manages the multi-file CoreML bundle itself (PT-P5-D2) —
/// `model_downloaded` carries a computed `DirectoryDigest` instead, and
/// `RefinementJob.modelSHA256` / `metadata.json` record `""`.
public struct WhisperKitModel: Sendable, Equatable {
    public let name: String
    public let variant: String
    /// Approximate download size, for the Settings caption.
    public let approximateDownloadMB: Int

    public init(name: String, variant: String, approximateDownloadMB: Int) {
        self.name = name
        self.variant = variant
        self.approximateDownloadMB = approximateDownloadMB
    }
}

/// The refine-pass model namespace — the only model knob PulsarTrace has.
/// (The live pass is fixed to Parakeet v3; see `ParakeetEngine`.)
public enum WhisperKitModelCatalog {

    /// Whisper large-v3-turbo, mixed-bit palettized (~626 MB). The
    /// production refinement default: near-large-v3 accuracy at a fraction
    /// of the decode cost, encoder + decoder on the ANE.
    public static let largeV3Turbo = WhisperKitModel(
        name: "large-v3-turbo",
        variant: "openai_whisper-large-v3-v20240930_626MB",
        approximateDownloadMB: 626)

    /// Full Whisper large-v3, quantized (~947 MB) — the accuracy fallback
    /// if turbo hallucinates on real audio (the PT-P5-D1 fallback rule: a
    /// Settings change, not a code change). Slower (32 decoder layers vs
    /// turbo's 4) but still on the ANE, off the GPU.
    public static let largeV3 = WhisperKitModel(
        name: "large-v3-whisperkit",
        variant: "openai_whisper-large-v3_947MB",
        approximateDownloadMB: 947)

    /// Picker/usage ordering — default first.
    public static let all: [WhisperKitModel] = [largeV3Turbo, largeV3]

    /// Production refine default.
    public static let defaultModel = largeV3Turbo

    /// `nil` for unknown names (including retired whisper.cpp names from
    /// old persisted settings) — callers fall back to `defaultModel`.
    public static func model(named name: String) -> WhisperKitModel? {
        all.first { $0.name == name }
    }
}
