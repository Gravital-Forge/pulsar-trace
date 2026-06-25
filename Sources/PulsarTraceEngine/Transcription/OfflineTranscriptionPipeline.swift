import Foundation
import Logging

/// Accumulates any `AudioFrameSource` into one contiguous Float32 buffer for
/// the offline/refine path.
///
/// The engine consumes audio *only* through `AudioFrameSource` (invariant 3).
/// For the offline path the whole stream is accumulated into one buffer before
/// transcription — with no chunking there are no chunk-boundary artifacts,
/// satisfying PT-R11. True streaming/overlap-windowing is the separate live pass
/// (`StreamingPipeline`).
public struct OfflineTranscriptionPipeline: Sendable {

    private let logger: Logger

    public init(logger: Logger = Logger(label: LogSubsystem.engine)) {
        self.logger = logger
    }

    /// Accumulate every frame from `source` into one buffer.
    ///
    /// Pause/resume markers carry no samples and are ignored here (the offline
    /// path has no wall-clock pacing). Returns the contiguous mono Float32 PCM.
    public func accumulate(_ source: some AudioFrameSource) async throws -> [Float] {
        try await source.start()
        var samples: [Float] = []
        for try await event in source {
            if case .frame(let frame) = event {
                samples.append(contentsOf: frame.samples)
            }
        }
        return samples
    }
}
