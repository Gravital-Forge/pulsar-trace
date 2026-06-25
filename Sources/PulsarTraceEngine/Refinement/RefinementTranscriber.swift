import Foundation

/// Backend-agnostic transcription seam for the one-shot CLI refine path
/// (`RefinementPipeline`), mirroring the closure shape `ResumableRefiner`
/// already uses on the queue path.
///
/// Contract:
/// - `detectRegions` returns the stream's speech regions; `[]` means "no
///   regions to slice by" and `transcribeRegions` then performs a
///   whole-buffer decode (WhisperKit's internal 30 s seek loop handles
///   arbitrary lengths). A throw is caught by the pipeline and treated
///   as `[]`.
/// - `transcribeRegions` returns recording-absolute segments.
public struct RefinementTranscriber: Sendable {
    public typealias DetectRegions =
        @Sendable ([Float]) async throws -> [SpeechRegion]
    public typealias TranscribeRegions =
        @Sendable ([Float], [SpeechRegion], TranscriptionOptions) async throws
        -> TranscriptionResult

    public let detectRegions: DetectRegions
    public let transcribeRegions: TranscribeRegions

    public init(
        detectRegions: @escaping DetectRegions,
        transcribeRegions: @escaping TranscribeRegions
    ) {
        self.detectRegions = detectRegions
        self.transcribeRegions = transcribeRegions
    }

    /// The production wiring: WhisperKit decode + FluidAudio VAD (PT-P5-D1).
    public static func whisperKit(
        _ transcriber: WhisperKitRegionTranscriber,
        vad: FluidVADRegionDetector
    ) -> RefinementTranscriber {
        RefinementTranscriber(
            detectRegions: { samples in
                try await vad.detectRegions(samples)
            },
            transcribeRegions: { samples, regions, options in
                try await transcriber.transcribe(
                    samples, regions: regions, options: options)
            })
    }
}
