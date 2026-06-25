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
    private var managerTask: Task<VadManager, Error>?

    public init(
        minTurnGap: Duration = .milliseconds(800),
        cacheRoot: URL = AppPaths.standard.modelsCacheDirectory,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.minTurnGap = minTurnGap
        self.cacheRoot = cacheRoot
        self.logger = logger
    }

    /// Detect coalesced speech regions in `samples`.
    ///
    /// - Important: `samples` must be 16 kHz mono Float32
    ///   (`AudioFormat.sampleRate`). The Silero VAD model has no notion of the
    ///   input rate, so passing any other rate silently yields wrong
    ///   timestamps (regions scaled by the rate ratio) rather than an error.
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
        if let managerTask {
            // A failed init must not be cached — clear it so the caller's
            // retry contract (fallback decision) can attempt a fresh load.
            do { return try await managerTask.value }
            catch {
                // Only the failed task's own awaiters may clear the slot — a
                // retry may already have stored a fresh task.
                if self.managerTask == managerTask { self.managerTask = nil }
                throw error
            }
        }
        let modelDirectory = cacheRoot.appendingPathComponent(
            "silero-vad-coreml", isDirectory: true)
        // Store the Task before awaiting so a concurrent detectRegions call
        // awaits the same in-flight init instead of racing a second
        // VadManager load against the same pinned directory (FluidAudio's
        // corrupted-cache recovery deletes + re-downloads).
        let task = Task { try await VadManager(modelDirectory: modelDirectory) }
        managerTask = task
        do { return try await task.value }
        catch {
            if self.managerTask == task { self.managerTask = nil }
            throw error
        }
    }
}
