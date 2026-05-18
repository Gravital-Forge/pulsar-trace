import Foundation
import Logging

/// The engine core: consumes any `AudioFrameSource` and counts frames.
///
/// This is deliberately minimal — it is the proof that the engine talks only
/// to the `AudioFrameSource` abstraction (invariant 3) and handles every
/// source's end-of-stream uniformly (R75). Higher-level passes replace the
/// body of the per-frame work with whisper streaming, diarization, and file
/// output; the source-consuming loop stays exactly as it is here.
public struct FrameConsumer: Sendable {

    /// Summary of a completed consumption run.
    public struct Result: Sendable, Equatable {
        /// Total number of `AudioFrame`s received.
        public let frameCount: Int
        /// Total number of PCM samples across all frames.
        public let sampleCount: Int
        /// Number of pause markers observed (R77).
        public let pauseCount: Int
        /// Total paused duration observed across resume markers.
        public let pausedDuration: Duration

        /// Audio duration implied by the frame count (frames × 20 ms).
        public var audioDuration: Duration {
            .milliseconds(frameCount * AudioFormat.frameMilliseconds)
        }
    }

    private let logger: Logger

    public init(logger: Logger = Logger(label: LogSubsystem.engine)) {
        self.logger = logger
    }

    /// Drive `source` to end-of-stream, counting frames and pause markers.
    ///
    /// Logs lifecycle at `notice` and a final summary — never any sample data
    /// (invariant 7: no content in logs).
    public func consume(_ source: some AudioFrameSource) async throws -> Result {
        try await source.start()
        logger.notice("Frame consumption started")

        var frameCount = 0
        var sampleCount = 0
        var pauseCount = 0
        var pausedDuration: Duration = .zero

        for try await event in source {
            switch event {
            case .frame(let frame):
                frameCount += 1
                sampleCount += frame.samples.count
            case .paused:
                pauseCount += 1
                logger.notice("Source paused")
            case .resumed(let gap):
                pausedDuration += gap
                logger.notice("Source resumed after gap")
            }
        }

        let result = Result(
            frameCount: frameCount,
            sampleCount: sampleCount,
            pauseCount: pauseCount,
            pausedDuration: pausedDuration
        )
        logger.notice(
            "Frame consumption finished; frames=\(frameCount), seconds=\(frameCount * 20 / 1000)")
        return result
    }
}
