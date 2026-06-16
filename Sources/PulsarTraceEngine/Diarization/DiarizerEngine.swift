import FluidAudio
import Foundation
import Logging

/// The resident FluidAudio offline-diarization stack (D40/D41) — pyannote
/// community-1 ported to CoreML, segmentation + WeSpeaker embeddings + AHC/VBx
/// clustering on the ANE. Owns two `OfflineDiarizerManager`s: one for the
/// offline refine pass (`Diarizer`) and one for the live windowed pass
/// (`LiveDiarizer`). Both use the same embedding model, so their embeddings
/// share one vector space (R29) and the speaker library compares across them;
/// they differ only in the AHC clustering threshold (D41 — see
/// `liveClusteringThreshold`). Each loads the (small) diarizer models
/// independently; the duplication is negligible next to the Parakeet/WhisperKit
/// residency and buys each manager FluidAudio's own prewarm + corrupt-cache
/// recovery. Models live at `<cacheRoot>/speaker-diarization/` (FluidAudio's
/// `DownloadUtils` appends `Repo.diarizer.folderName`, which strips the
/// `-coreml` suffix, to the directory it is handed) — the same D10 cache root
/// Parakeet and FluidVAD use.
public actor DiarizerEngine {

    /// The model name recorded in `model_downloaded` events — the public HF
    /// repo identity, matching `DiarizationResultMapper.modelId`.
    public static let modelName = "speaker-diarization-coreml"
    /// The on-disk repo folder under the cache root. FluidAudio's
    /// `Repo.diarizer.folderName` strips the `-coreml` suffix from the repo
    /// name, so the bundles land at `<cacheRoot>/speaker-diarization/`
    /// (verified against the v0.15.2 checkout + the actual download).
    public static let repoFolderName = "speaker-diarization"
    /// Model bundles whose presence marks the cache as already populated.
    private static let requiredBundles = [
        "Segmentation.mlmodelc", "FBank.mlmodelc",
        "Embedding.mlmodelc", "PldaRho.mlmodelc",
    ]

    /// AHC agglomerative-clustering distance threshold for the LIVE windowed
    /// path (D41). FluidAudio's default (0.6) over-splits a single speaker on
    /// the short (~10 s) windows the live pass feeds it: on a real 2-speaker
    /// recording the live bank formed 3 provisional keys — one a spurious
    /// within-speaker fragment that the R18 lookup confidently mis-named to a
    /// third library speaker (cosine 0.91). Raising the threshold merges those
    /// fragments while genuinely distinct speakers stay split. Calibrated
    /// 2026-06-15 (live path, 10 s window / 5 s step + the 0.45 cosine stitch):
    /// at 1.05 the same recording yields exactly 2 keys → Mateusz + Stanisław
    /// (0.95 / 0.92); the committed `single-speaker-30s` fixture stays 1 and
    /// `two-speakers-alternating` stays 2; the validated-safe band is 1.05–1.20
    /// (max is √2, enforced by `OfflineDiarizerConfig.validate()`). The refine
    /// pass keeps FluidAudio's 0.6 default — whole-file evidence clusters
    /// correctly and is the source of truth (R16).
    static let liveClusteringThreshold = 1.05

    /// `OfflineDiarizerManager` is a non-Sendable `final class`. This actor is
    /// the sole owner of both managers and every `process` call goes through an
    /// actor-isolated `diarize` method. Actors are reentrant across `await`, so
    /// two `process` calls on one manager CAN overlap — but only when a caller
    /// abandons a cancelled call still winding down (the live window-timeout
    /// path), and CoreML `MLModel.prediction` is documented thread-safe.
    /// `nonisolated(unsafe)` accepts that bounded overlap; do not add callers
    /// that run uncancelled `diarize` calls concurrently on the same manager.
    /// The refine and live managers are separate instances with separate model
    /// objects, so the refine pass and a live window never contend.
    private nonisolated(unsafe) let refineManager: OfflineDiarizerManager
    private nonisolated(unsafe) let liveManager: OfflineDiarizerManager
    /// Content digest of the model directory — the authoritative model
    /// identity. The speaker library keys centroid compatibility on this
    /// (Open Question #3 / D40): it changes exactly when the model content
    /// changes.
    public nonisolated let modelRevision: String

    private init(
        refineManager: OfflineDiarizerManager,
        liveManager: OfflineDiarizerManager,
        modelRevision: String
    ) {
        self.refineManager = refineManager
        self.liveManager = liveManager
        self.modelRevision = modelRevision
    }

    /// Download (first run only; ~21 MB from huggingface.co — the permitted
    /// model-download network call; the repo is public, no token) and load the
    /// diarizer models from `<cacheRoot>/speaker-diarization`. Emits
    /// `model_downloaded` with a `DirectoryDigest` after a fresh download
    /// (D39 digest pattern).
    ///
    /// Call once per process and share the returned engine.
    public static func load(
        cacheRoot: URL,
        events: EventWriter?,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) async throws -> DiarizerEngine {
        let modelDir = cacheRoot.appendingPathComponent(
            repoFolderName, isDirectory: true)
        let existedBefore = requiredBundles.allSatisfy {
            FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent($0).path)
        }

        logger.notice("diarizer: ensuring models available (cached=\(existedBefore))")
        var config = OfflineDiarizerConfig.default
        // Keep overlap-preserving spans: the transcript merge's 30 %
        // co-attribution rule (D11) needs overlapping speaker spans.
        config.postProcessing.exclusiveSegments = false
        // VBx evidence weight, raised from FluidAudio's 0.07 default (D40).
        // At 0.07 the clusterer collapses two clearly-distinct voices
        // (cross-speaker cosine 0.38, same-speaker 0.93) into one cluster on
        // recordings shorter than ~1 minute — VBx's prior dominates until
        // enough audio accumulates (the same 24 s clip separates at 72 s).
        // Measured on the committed fixtures: every Fa in 0.08…0.3 separates
        // the two-speaker clip and none splits a 2-minute single-speaker
        // clip; 0.2 sits well clear of the 0.07/0.08 boundary. Under-
        // separation is the worse failure (two people fused under one label,
        // unfixable post-hoc); over-split has a user remedy (speaker merge).
        config.clustering.warmStartFa = 0.2

        // Refine pass: FluidAudio's default AHC threshold (0.6) — whole-file
        // evidence clusters correctly; this pass is the source of truth.
        let refineManager = OfflineDiarizerManager(config: config)
        try await refineManager.prepareModels(directory: cacheRoot)

        // Live pass: identical config but a higher AHC threshold so a single
        // speaker does not over-split on the short windows it processes (D41).
        var liveConfig = config
        liveConfig.clustering.threshold = liveClusteringThreshold
        let liveManager = OfflineDiarizerManager(config: liveConfig)
        try await liveManager.prepareModels(directory: cacheRoot)

        // The digest is required (not best-effort like Parakeet's): it IS the
        // modelRevision the speaker library scopes centroids by.
        let digest = try DirectoryDigest.compute(at: modelDir)
        if !existedBefore, let events {
            _ = try? await events.append(ModelDownloadedEvent(
                modelName: modelName,
                sizeBytes: digest.totalBytes,
                sha256: digest.sha256,
                sourceHost: "huggingface.co"))
        }
        logger.notice("diarizer: models resident (revision \(digest.sha256.prefix(12))…)")
        return DiarizerEngine(
            refineManager: refineManager,
            liveManager: liveManager,
            modelRevision: digest.sha256)
    }

    /// Diarize a buffer of 16 kHz mono Float32 samples (the live windowed
    /// path). Silent audio yields an empty result, never an error.
    public func diarize(samples: [Float]) async throws -> DiarizationResult {
        let duration = Duration.milliseconds(
            samples.count * 1000 / AudioFormat.sampleRate)
        do {
            // `raw` is `FluidAudio.DiarizationResult`, which can't be named in
            // this module — `public struct FluidAudio` shadows the module name
            // for member-type lookup, and unqualified `DiarizationResult`
            // resolves to ours. Letting it stay inferred and adapting it to the
            // mapper's primitives inline (`mapped(rawSegments:rawDatabase:)`)
            // sidesteps the collision.
            let raw = try await liveManager.process(audio: samples)
            return mapped(
                rawSegments: raw.segments.map {
                    .init(
                        speakerId: $0.speakerId,
                        start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds))
                },
                rawDatabase: raw.speakerDatabase ?? [:],
                audioDuration: duration)
        } catch let e as OfflineDiarizationError {
            if case .noSpeechDetected = e {
                return emptyResult(audioDuration: duration)
            }
            throw e
        }
    }

    /// Diarize a WAV file (the offline refine path). FluidAudio memory-maps
    /// and resamples to 16 kHz itself, so arbitrary input WAVs are fine.
    /// Silent audio yields an empty result, never an error.
    public func diarize(wavPath: URL) async throws -> DiarizationResult {
        let seconds = WAVReader.probeDurationSeconds(at: wavPath) ?? 0
        let duration = Duration.milliseconds(Int((seconds * 1000).rounded()))
        do {
            let raw = try await refineManager.process(wavPath)
            return mapped(
                rawSegments: raw.segments.map {
                    .init(
                        speakerId: $0.speakerId,
                        start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds))
                },
                rawDatabase: raw.speakerDatabase ?? [:],
                audioDuration: duration)
        } catch let e as OfflineDiarizationError {
            if case .noSpeechDetected = e {
                return emptyResult(audioDuration: duration)
            }
            throw e
        }
    }

    private func mapped(
        rawSegments: [DiarizationResultMapper.Segment],
        rawDatabase: [String: [Float]],
        audioDuration: Duration
    ) -> DiarizationResult {
        DiarizationResultMapper.map(
            segments: rawSegments,
            speakerDatabase: rawDatabase,
            audioDuration: audioDuration,
            modelRevision: modelRevision)
    }

    private func emptyResult(audioDuration: Duration) -> DiarizationResult {
        DiarizationResultMapper.map(
            segments: [], speakerDatabase: [:],
            audioDuration: audioDuration, modelRevision: modelRevision)
    }
}
