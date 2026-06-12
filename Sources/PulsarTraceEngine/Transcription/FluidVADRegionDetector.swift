import FluidAudio
import Foundation
import Logging

/// Speech-region detection for the ANE refine path: FluidAudio's Silero
/// VAD (CoreML, `.cpuAndNeuralEngine` by default) replaces whisper.cpp's
/// built-in Silero (the old `WhisperTranscriber.detectSpeechRegions`) so
/// the WhisperKit pipeline never has to construct a ggml context.
///
/// Regions are coalesced with the same 800 ms `minTurnGap` rule via
/// `SpeechRegion.coalesced` — the D26 turn-sizing contract (final.md breaks
/// at genuine conversational pauses) is backend-independent.
///
/// The VAD model (~small, `FluidInference/silero-vad-coreml`) is loaded
/// lazily on first use and pinned under the shared PulsarTrace cache root
/// (`<cacheRoot>/silero-vad-coreml`, D10 one-cache-root) via FluidAudio's
/// `modelDirectory:` init parameter; FluidAudio caches it. A failure here is
/// the caller's fallback decision (whole-buffer decode / one whole-file
/// region).
public actor FluidVADRegionDetector {

    private let minTurnGap: Duration
    private let cacheRoot: URL
    private let logger: Logger
    private var manager: VadManager?

    public init(
        minTurnGap: Duration = .milliseconds(800),
        cacheRoot: URL = ModelStore.defaultCacheDirectory(),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.minTurnGap = minTurnGap
        self.cacheRoot = cacheRoot
        self.logger = logger
    }

    public func detectRegions(_ samples: [Float]) async throws -> [SpeechRegion] {
        guard !samples.isEmpty else { return [] }
        let manager = try await ensureManager()
        let segments = try await manager.segmentSpeech(samples)
        let raw = segments.map { segment in
            SpeechRegion(
                start: .milliseconds(Int((segment.startTime * 1000).rounded())),
                end: .milliseconds(Int((segment.endTime * 1000).rounded())))
        }
        let coalesced = SpeechRegion.coalesced(raw, minGap: minTurnGap)
        logger.notice("fluid VAD: \(raw.count) region(s) → \(coalesced.count) turn(s)")
        return coalesced
    }

    private func ensureManager() async throws -> VadManager {
        if let manager { return manager }
        let modelDirectory = cacheRoot.appendingPathComponent(
            "silero-vad-coreml", isDirectory: true)
        let created = try await VadManager(modelDirectory: modelDirectory)
        manager = created
        return created
    }
}
