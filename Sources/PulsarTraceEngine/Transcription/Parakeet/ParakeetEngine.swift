import FluidAudio
import Foundation
import Logging

/// The resident Parakeet TDT 0.6B v3 model (live pass, PT-R10) — loaded once
/// per process and shared by the system and mic stream transcribers. The
/// live pass has exactly one backend; there is no live model knob (PT-P5-D1).
///
/// FluidAudio's `AsrManager` is an actor, so concurrent window decodes from
/// the two streams serialize automatically (the in-process analogue of the
/// old whisper subprocess's `SerializingHostProxy`). Each window decodes
/// with a **fresh** `TdtDecoderState`: streaming windows overlap, and
/// reusing decoder state across them would let one window's tail condition
/// the next — the same reason the whisper path set `no_context = true`.
/// Compute units: FluidAudio's defaults are already `.cpuAndNeuralEngine`
/// (preprocessor `.cpuOnly` by design) — the GPU is never touched.
public actor ParakeetEngine {

    /// The model name recorded in events (`recording_started.model_live`).
    /// Not user-selectable.
    public static let modelName = "parakeet-v3"
    /// The Hugging Face repo folder name. The cache directory's last path
    /// component MUST be exactly this: `AsrModels.download(to:)` re-derives
    /// the model path as `directory.deletingLastPathComponent() +
    /// <repo folder name>` (verified v0.15.2 AsrModels.swift `repoPath`).
    public static let repoFolderName = "parakeet-tdt-0.6b-v3-coreml"

    /// One decoded window: the raw text plus per-token timings (window-
    /// relative seconds), pre-adapted to the mapper's input type.
    public struct WindowDecode: Sendable {
        public let text: String
        public let tokens: [ParakeetTokenMapper.InputToken]
    }

    private let manager: AsrManager
    private let decoderLayers: Int

    private init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.decoderLayers = decoderLayers
    }

    /// The "Restrict to languages" → script-hint rule (scope decision 3):
    /// exactly one allowed code → that code (normalized); zero or several →
    /// `nil` (auto). Pure, so it unit-tests without a model; the code →
    /// `FluidAudio.Language` mapping happens inside `transcribeWindow`.
    public static func languageHint(from allowedLanguages: [String]) -> String? {
        guard allowedLanguages.count == 1 else { return nil }
        return allowedLanguages[0].lowercased()
    }

    /// Download (first run only; ~0.5 GB from huggingface.co — the permitted
    /// model-download network call) and load the model from
    /// `<cacheRoot>/parakeet-tdt-0.6b-v3-coreml`, keeping every PulsarTrace
    /// model under one cache root (PT-P1-D10). Emits `model_downloaded` with a
    /// `DirectoryDigest` after a fresh download (PT-P5-D1).
    ///
    /// Call once per process and share the returned engine; concurrent `load`
    /// calls race the same download directory.
    public static func load(
        cacheRoot: URL,
        events: EventWriter?,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) async throws -> ParakeetEngine {
        let modelDir = cacheRoot.appendingPathComponent(
            repoFolderName, isDirectory: true)
        let existedBefore = AsrModels.modelsExist(at: modelDir)

        logger.notice("parakeet: ensuring model available (cached=\(existedBefore))")
        let models = try await AsrModels.downloadAndLoad(to: modelDir, version: .v3)

        if !existedBefore, let events {
            // Best-effort: a digest failure must never fail a live session.
            do {
                let digest = try DirectoryDigest.compute(at: modelDir)
                _ = try await events.append(ModelDownloadedEvent(
                    modelName: modelName,
                    sizeBytes: digest.totalBytes,
                    sha256: digest.sha256,
                    sourceHost: "huggingface.co"))
            } catch {
                // DirectoryDigest.compute can rethrow raw NSErrors embedding
                // full home paths — redact before logging.
                logger.warning("parakeet: model_downloaded not emitted: \(PathRedactor.redactHome("\(error)"))")
            }
        }

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        logger.notice("parakeet: model resident (decoderLayers=\(layers))")
        return ParakeetEngine(manager: manager, decoderLayers: layers)
    }

    /// Decode one streaming window.
    ///
    /// `languageHint` is the resolved single allowed code (`languageHint(from:)`)
    /// or `nil` for auto. The code is mapped to FluidAudio's script-aware
    /// `Language` here; a code FluidAudio doesn't know (e.g. `"ja"` — the
    /// enum covers Latin/Cyrillic/Greek scripts only) maps to `nil`, i.e.
    /// auto — never an error.
    ///
    /// `Language` is referenced unqualified: FluidAudio exposes it as a
    /// top-level `public enum Language: String` (Shared/TokenLanguageFilter),
    /// so the module-qualified `FluidAudio.Language` does not resolve in
    /// v0.15.2 — same enum, same semantics.
    public func transcribeWindow(
        _ samples: [Float],
        languageHint: String? = nil
    ) async throws -> WindowDecode {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let language = languageHint.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(
            samples, decoderState: &state, language: language)
        let tokens = (result.tokenTimings ?? []).map {
            ParakeetTokenMapper.InputToken(
                token: $0.token, start: $0.startTime, end: $0.endTime)
        }
        return WindowDecode(text: result.text, tokens: tokens)
    }
}
