import Foundation

/// A pinned, downloadable ggml model file — a whisper transcription model or
/// the Silero VAD model.
///
/// Each entry pins a SHA-256 (R54d) and the expected byte size. Hashes are the
/// git-LFS `oid` values published in the model's Hugging Face repo. A download
/// whose bytes don't match the pinned hash is deleted and retried — no
/// unverified model is ever loaded into memory.
public struct WhisperModel: Sendable, Equatable {
    /// Stable short name; for transcription models also the `--model` CLI
    /// value (`base`, `large-v3`).
    public let name: String
    /// The ggml file name in the Hugging Face repo (`ggml-base.bin`).
    public let fileName: String
    /// Pinned lowercase-hex SHA-256 of the file (R54d).
    public let sha256: String
    /// Expected file size in bytes — used to validate Range-resume offsets.
    public let sizeBytes: Int
    /// The Hugging Face repo (`owner/name`) hosting the file. Defaults to the
    /// whisper.cpp model repo; the VAD model lives in a different repo.
    public let repoPath: String

    public init(
        name: String,
        fileName: String,
        sha256: String,
        sizeBytes: Int,
        repoPath: String = ModelCatalog.repoPath
    ) {
        self.name = name
        self.fileName = fileName
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.repoPath = repoPath
    }
}

/// The pinned whisper model catalogue (R54d).
public enum ModelCatalog {

    /// Hugging Face host serving the ggml model files — public, no token.
    public static let huggingFaceHost = "huggingface.co"
    /// Default Hugging Face repo — hosts the ggml whisper models.
    public static let repoPath = "ggerganov/whisper.cpp"

    /// `ggml-base.bin` — multilingual, ~150 MB. The test/CI model (D4).
    public static let base = WhisperModel(
        name: "base",
        fileName: "ggml-base.bin",
        sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        sizeBytes: 147_951_465
    )

    /// `ggml-large-v3.bin` — multilingual, ~3 GB. The production refinement
    /// default.
    public static let largeV3 = WhisperModel(
        name: "large-v3",
        fileName: "ggml-large-v3.bin",
        sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        sizeBytes: 3_095_033_483
    )

    /// The Silero VAD model whisper.cpp's built-in VAD loads (`--vad`).
    ///
    /// Used by the offline refine pass to drop non-speech regions before
    /// transcription. Hosted in `ggml-org/whisper-vad`, not the whisper repo.
    /// Small (~1 MB), so the first refine fetches it almost instantly.
    public static let sileroVAD = WhisperModel(
        name: "silero-vad",
        fileName: "ggml-silero-v5.1.2.bin",
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
        sizeBytes: 885_098,
        repoPath: "ggml-org/whisper-vad"
    )

    /// All pinned transcription models — the `--model` choices.
    public static let all: [WhisperModel] = [base, largeV3]

    /// Resolve a `--model` value to a transcription-model catalogue entry.
    /// The VAD model is intentionally excluded — it is not a `--model` choice.
    public static func model(named name: String) -> WhisperModel? {
        all.first { $0.name == name }
    }

    /// The public download URL for a model file.
    public static func downloadURL(for model: WhisperModel) -> URL {
        // No query params — not even `?version=`. A version ping is telemetry.
        URL(string: "https://\(huggingFaceHost)/\(model.repoPath)/resolve/main/\(model.fileName)")!
    }
}
