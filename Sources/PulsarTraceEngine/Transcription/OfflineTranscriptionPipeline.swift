import Foundation
import Logging

/// Drives offline transcription end-to-end: any `AudioFrameSource` → one
/// contiguous Float32 buffer → a single `whisper_full` call → R13 markdown.
///
/// The engine consumes audio *only* through `AudioFrameSource` (invariant 3).
/// For the offline path the whole stream is accumulated into one buffer before
/// transcription — with no chunking there are no chunk-boundary artifacts,
/// satisfying R11. True streaming/overlap-windowing is the separate live pass
/// (`StreamingPipeline`).
public struct OfflineTranscriptionPipeline: Sendable {

    /// The outcome of an offline transcription run.
    public struct Output: Sendable {
        /// The rendered R13 markdown document.
        public let markdown: String
        /// The structured transcript (for callers that want the segments).
        public let document: TranscriptDocument
        /// whisper's detected/used language.
        public let language: String
        /// Audio duration accumulated from the source.
        public let audioDuration: Duration
    }

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

    /// Transcribe `source` with `transcriber` and render the R13 document.
    ///
    /// - Parameters:
    ///   - source: any conforming audio source (fixture, pipe, socket).
    ///   - transcriber: a model-resident `WhisperTranscriber`.
    ///   - recordingStart: wall-clock start used for the document header
    ///     (defaults to now; tests pin it for deterministic snapshots).
    ///   - options: whisper decode options (deterministic defaults).
    public func run(
        source: some AudioFrameSource,
        transcriber: WhisperTranscriber,
        recordingStart: Date = Date(),
        options: WhisperTranscriber.Options = .init()
    ) async throws -> Output {
        let samples = try await accumulate(source)
        let duration = Duration.milliseconds(
            samples.count * 1000 / AudioFormat.sampleRate)
        let seconds = samples.count / AudioFormat.sampleRate
        logger.notice(
            "offline transcription: accumulated \(samples.count) samples (\(seconds)s)")

        let result = try transcriber.transcribe(samples, options: options)
        let document = TranscriptDocument(
            recordingStart: recordingStart,
            segments: result.segments,
            marker: .final
        )
        return Output(
            markdown: document.render(),
            document: document,
            language: result.language,
            audioDuration: duration
        )
    }
}
