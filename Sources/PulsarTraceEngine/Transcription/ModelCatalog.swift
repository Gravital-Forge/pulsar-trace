import Foundation

/// The whisper models PulsarTrace knows how to download and verify.
///
/// Each entry pins a SHA-256 (R54d) and the expected byte size. Hashes are the
/// git-LFS `oid` values published in the `ggerganov/whisper.cpp` Hugging Face
/// repo. A download whose bytes don't match the pinned hash is deleted and
/// retried — no unverified model is ever loaded into memory.
public struct WhisperModel: Sendable, Equatable {
    /// Stable short name, also the `--model` CLI value (`base`, `large-v3`).
    public let name: String
    /// The ggml file name in the Hugging Face repo (`ggml-base.bin`).
    public let fileName: String
    /// Pinned lowercase-hex SHA-256 of the file (R54d).
    public let sha256: String
    /// Expected file size in bytes — used to validate Range-resume offsets.
    public let sizeBytes: Int

    public init(name: String, fileName: String, sha256: String, sizeBytes: Int) {
        self.name = name
        self.fileName = fileName
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

/// The pinned whisper model catalogue (R54d).
public enum ModelCatalog {

    /// Hugging Face repo hosting the ggml whisper models — public, no token.
    public static let huggingFaceHost = "huggingface.co"
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

    /// All pinned models.
    public static let all: [WhisperModel] = [base, largeV3]

    /// Resolve a `--model` value to a catalogue entry.
    public static func model(named name: String) -> WhisperModel? {
        all.first { $0.name == name }
    }

    /// The public download URL for a model file.
    public static func downloadURL(for model: WhisperModel) -> URL {
        // No query params — not even `?version=`. A version ping is telemetry.
        URL(string: "https://\(huggingFaceHost)/\(repoPath)/resolve/main/\(model.fileName)")!
    }
}
