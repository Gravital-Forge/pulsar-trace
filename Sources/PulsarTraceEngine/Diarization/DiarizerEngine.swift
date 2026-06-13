import FluidAudio
import Foundation
import Logging

/// The resident FluidAudio offline-diarization stack (D40) — pyannote
/// community-1 ported to CoreML, segmentation + WeSpeaker embeddings + VBx
/// clustering on the ANE. Loaded once per process and shared by the offline
/// refine pass (`Diarizer`) and the live windowed pass (`LiveDiarizer`), so
/// both produce embeddings in the same vector space (R29).
///
/// `OfflineDiarizerManager` is a non-Sendable class; this actor owns it and
/// serializes access. Models live at `<cacheRoot>/speaker-diarization/`
/// (FluidAudio's `DownloadUtils` appends `Repo.diarizer.folderName`, which
/// strips the `-coreml` suffix, to the directory it is handed) — the same D10
/// cache root Parakeet and FluidVAD use.
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

    /// `OfflineDiarizerManager` is a non-Sendable `final class`. This actor is
    /// its sole owner and every `process` call goes through an actor-isolated
    /// `diarize` method. Actors are reentrant across `await`, so two `process`
    /// calls CAN overlap — but only when a caller abandons a cancelled call
    /// that is still winding down (the live window-timeout path), and CoreML
    /// `MLModel.prediction` is documented thread-safe. `nonisolated(unsafe)`
    /// accepts that bounded overlap; do not add callers that run uncancelled
    /// `diarize` calls concurrently on one engine instance.
    private nonisolated(unsafe) let manager: OfflineDiarizerManager
    /// Content digest of the model directory — the authoritative model
    /// identity. The speaker library keys centroid compatibility on this
    /// (Open Question #3 / D40): it changes exactly when the model content
    /// changes.
    public nonisolated let modelRevision: String

    private init(manager: OfflineDiarizerManager, modelRevision: String) {
        self.manager = manager
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
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: cacheRoot)

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
        return DiarizerEngine(manager: manager, modelRevision: digest.sha256)
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
            let raw = try await manager.process(audio: samples)
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
            let raw = try await manager.process(wavPath)
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
