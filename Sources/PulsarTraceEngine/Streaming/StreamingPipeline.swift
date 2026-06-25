import Foundation
import Logging

/// The live pass, end to end.
///
/// Drives one or two `AudioFrameSource`s at real-time pace and grows an
/// append-only `live.md` so an external AI agent can `tail -f` it during a
/// meeting. The offline `pulsartrace refine` pass remains the source of truth;
/// this is the low-latency companion (the two-pass live/refine model).
///
/// ## What it wires together
///
/// - `StreamingTranscriber` — sliding-window decode + LocalAgreement-2,
///   producing **committed** utterances ≤ 5 s behind real time (PT-R10).
/// - `LiveDiarizer` — windowed in-process (ANE) provisional speaker IDs for the
///   system stream (PT-R15, PT-R16). Optional: when unavailable the system stream is
///   still transcribed, but with no diarization coverage every system utterance
///   is labelled the neutral `Speaker?` (§2b).
/// - `SpeakerLibrary` — opened **read-only** (PT-R18, PT-R32): a provisional speaker
///   whose centroid matches a known library speaker is shown by name. The live
///   pass **never writes** to the library — invariant #5.
/// - `MicEchoDedup` — drops a mic utterance that is an echo of a system
///   utterance (PT-R19).
/// - `LiveMarkdownWriter` — strictly append-only `live.md` (PT-R12, PT-R35a, PT-R36).
///
/// ## Stream mapping (single-pipe input)
///
/// A single `--stdin` / `--source fixture` stream is treated as the **system
/// stream**: it is diarized and labelled `Them …`. This matches the
/// bare-WAV rule (a lone stream is system audio) and the framing that the
/// system stream is "the one or more Them-speakers". The mic stream is opt-in:
/// when a paired mic source is supplied, its utterances are `You` and never
/// diarized (PT-R17), and run through mic-echo dedup against the system stream.
public struct StreamingPipeline: Sendable {

    /// Inputs and tunables for one live run.
    public struct Configuration: Sendable {
        /// The system-audio source — diarized, `Them …` labels.
        public let recordingFolder: URL
        /// Wall-clock recording start (PT-R35a header, transcript offsets).
        public let recordingStart: Date
        /// Recording id for the `live_md_started` event.
        public let recordingId: String
        /// Streaming-transcription tunables.
        public let transcriberConfig: StreamingTranscriber.Configuration
        /// Raw per-window diarizer for the live windowed pass — in production
        /// the in-process `DiarizerEngineRawAdapter` over the shared
        /// `DiarizerEngine` actor.
        /// `nil` → no live diarization (no coverage → neutral `Speaker?`, §2b).
        public let liveRawDiarizer: (any RawWindowDiarizing)?
        /// How often the system stream is handed to the live diarizer, and the
        /// window length it sees.
        public let diarizationStep: Duration
        public let diarizationWindow: Duration

        public init(
            recordingFolder: URL,
            recordingStart: Date,
            recordingId: String,
            transcriberConfig: StreamingTranscriber.Configuration = .init(),
            liveRawDiarizer: (any RawWindowDiarizing)? = nil,
            diarizationStep: Duration = .seconds(5),
            diarizationWindow: Duration = .seconds(10)
        ) {
            self.recordingFolder = recordingFolder
            self.recordingStart = recordingStart
            self.recordingId = recordingId
            self.transcriberConfig = transcriberConfig
            self.liveRawDiarizer = liveRawDiarizer
            self.diarizationStep = diarizationStep
            self.diarizationWindow = diarizationWindow
        }

        /// `live.md` destination inside the recording folder.
        var liveURL: URL {
            recordingFolder.appendingPathComponent(RecordingFolder.FileName.live)
        }
    }

    /// Outcome of a live run — for tests and the CLI summary.
    public struct Output: Sendable {
        /// The `live.md` that was grown.
        public let liveURL: URL
        /// Total bytes written to `live.md` (strictly increased over the run).
        public let bytesWritten: Int
        /// Utterance lines appended (excludes the marker + header).
        public let utteranceLines: Int
        /// Mic utterances dropped as echoes of system audio (PT-R19).
        public let micEchoesDropped: Int
        /// Median live transcription lag — the PT-R10 metric: the median gap
        /// between real time and a committed utterance's end, over mid-stream
        /// commits (the end-of-stream flush is excluded).
        public let medianLagSeconds: Double
        /// Worst mid-stream lag observed.
        public let maxLagSeconds: Double
        /// The decoder's detected language for the system stream.
        public let language: String
    }

    private let events: EventWriter?
    private let logger: Logger

    public init(
        events: EventWriter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.events = events
        self.logger = logger
    }

    /// Run the live pass over a system source (and an optional mic source).
    ///
    /// - Parameters:
    ///   - configuration: inputs + tunables.
    ///   - systemTranscriber: a `WindowTranscribing` conformer for the system
    ///     stream — `ParakeetWindowTranscriber` in production live runs (PT-P5-D1),
    ///     one transcriber per stream.
    ///   - micTranscriber: a separate `WindowTranscribing` for the mic stream,
    ///     when a `micSource` is supplied.
    ///   - systemSource: the system-audio `AudioFrameSource` (any conforming
    ///     source — fixture, pipe, socket).
    ///   - micSource: optional mic `AudioFrameSource` (paired-stream mode).
    ///   - library: speaker library opened **read-only** for the live name
    ///     lookup (PT-R18). `nil` → generic `Them` labels only.
    public func run(
        configuration: Configuration,
        systemTranscriber: any WindowTranscribing,
        micTranscriber: (any WindowTranscribing)? = nil,
        systemSource: some AudioFrameSource,
        micSource: (any AudioFrameSource)? = nil,
        library: SpeakerLibrary? = nil
    ) async throws -> Output {

        // --- live.md created at session start (PT-R35a) ------------------------
        let writer = LiveMarkdownWriter(
            fileURL: configuration.liveURL,
            recordingStart: configuration.recordingStart)
        try await writer.start()
        // Event AFTER the file + header exist on disk (Hard Invariant #8).
        _ = try? await events?.append(LiveMDStartedEvent(
            recordingId: configuration.recordingId,
            pathBasename: RecordingFolder.FileName.live))
        logger.notice("live.md created — live pass started")

        // --- live diarization (in-process, optional) -------------------------
        var liveDiarizer: LiveDiarizer?
        if let raw = configuration.liveRawDiarizer {
            liveDiarizer = LiveDiarizer(rawDiarizer: raw, logger: logger)
        }
        // --- run the streams ------------------------------------------------
        let runner = LiveRunner(
            configuration: configuration,
            writer: writer,
            logger: logger,
            library: library)
        let output: StreamingPipeline.Output
        do {
            output = try await runner.run(
                systemTranscriber: systemTranscriber,
                micTranscriber: micTranscriber,
                systemSource: systemSource,
                micSource: micSource,
                liveDiarizer: liveDiarizer)
        } catch {
            // Always close the file, even on a throw. The in-process diarizer
            // holds no resources to release — no subprocess, no scratch WAVs.
            await writer.finish()
            throw error
        }

        await writer.finish()
        let lines = output.utteranceLines
        let echoes = output.micEchoesDropped
        logger.notice(
            "live pass finished — \(lines) line(s), \(echoes) mic echo(es) dropped")
        return output
    }
}
