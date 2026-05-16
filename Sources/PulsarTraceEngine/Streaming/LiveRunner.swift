import Foundation
import Logging

/// Drives the live pass's streams and turns committed utterances into
/// append-only `live.md` lines (Epic 6). The execution core behind
/// `StreamingPipeline`.
///
/// Split out of `StreamingPipeline` so the wiring (file creation, events,
/// subprocess lifecycle) stays separate from the per-frame run loop.
///
/// ## Concurrency design
///
/// The system and mic streams must be consumed *concurrently* so both run at
/// real-time pace. But a `WhisperTranscriber` is not `Sendable` (it owns a
/// `whisper_context`), so the transcribers cannot be captured into child
/// tasks. The resolution: the **frame reading** runs on child tasks (an
/// `AudioFrameSource` *is* `Sendable`, only its iterator is not), each feeding
/// a single `AsyncStream` of `(stream, frame)` tuples. The run loop then
/// consumes that merged stream on one task, holding both transcribers as
/// locals — so whisper is only ever touched from one task and `live.md` only
/// ever sees one append at a time.
final class LiveRunner: Sendable {

    /// Which physical stream a merged frame came from.
    enum StreamTag: Sendable { case system, mic }
    /// One merged-stream item: a frame plus its origin, a pause/resume marker
    /// (Epic 7 — capture daemon sleep/wake), or an end marker.
    enum MergedItem: Sendable {
        case frame(StreamTag, AudioFrame)
        /// The stream paused (capture daemon: system sleep / device change).
        case paused(StreamTag)
        /// The stream resumed; carries which one and the paused gap.
        case resumed(StreamTag, Duration)
        /// A stream ended; carries which one.
        case ended(StreamTag)
    }

    private let configuration: StreamingPipeline.Configuration
    private let writer: LiveMarkdownWriter
    private let logger: Logger
    private let library: SpeakerLibrary?

    init(
        configuration: StreamingPipeline.Configuration,
        writer: LiveMarkdownWriter,
        logger: Logger,
        library: SpeakerLibrary?
    ) {
        self.configuration = configuration
        self.writer = writer
        self.logger = logger
        self.library = library
    }

    func run(
        systemTranscriber: WhisperTranscriber,
        micTranscriber: WhisperTranscriber?,
        systemSource: some AudioFrameSource,
        micSource: (any AudioFrameSource)?,
        liveDiarizer: LiveDiarizer?
    ) async throws -> StreamingPipeline.Output {

        let sink = LiveSink(
            writer: writer,
            recordingStart: configuration.recordingStart)
        let hasMic = micSource != nil && micTranscriber != nil

        // --- merged frame stream --------------------------------------------
        // Child tasks read frames off each Sendable source and push tagged
        // items into one stream; the run loop below consumes it.
        let (merged, continuation) = AsyncStream.makeStream(of: MergedItem.self)
        let startWall = ContinuousClock.now

        let readers = Task { [systemSource] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.pump(.system, source: systemSource,
                                    into: continuation)
                }
                if let micSource {
                    group.addTask {
                        await Self.pump(.mic, source: micSource,
                                        into: continuation)
                    }
                }
                await group.waitForAll()
                continuation.finish()
            }
        }

        // --- per-stream transcription state (locals — never escape) ---------
        let systemStreamer = StreamingTranscriber(
            transcriber: systemTranscriber,
            configuration: configuration.transcriberConfig,
            logger: logger)
        let micStreamer = micTranscriber.map {
            StreamingTranscriber(
                transcriber: $0,
                configuration: configuration.transcriberConfig,
                logger: logger)
        }

        // The full system + mic audio, captured so the live pass leaves a
        // recording folder a later `pulsartrace refine` can consume. The
        // system buffer doubles as the live-diarizer's window source.
        var diarBuffer: [Float] = []
        var micBuffer: [Float] = []
        let diarStep = durationToSamples(configuration.diarizationStep)
        let diarWindow = durationToSamples(configuration.diarizationWindow)
        var lastDiarEnd = 0
        let diarState = DiarState()

        var systemDone = false
        var micDone = !hasMic

        // --- the run loop ---------------------------------------------------
        for await item in merged {
            let elapsed = ContinuousClock.now - startWall
            switch item {
            case .frame(.system, let frame):
                for utt in systemStreamer.ingest(
                    frame: frame, realTimeElapsed: elapsed) {
                    let label = await resolveSystemLabel(
                        for: utt, diarState: diarState, diarizer: liveDiarizer)
                    await sink.appendSystemUtterance(
                        utt, label: label, realElapsed: elapsed)
                }
                // Feed a diarization window on cadence.
                diarBuffer.append(contentsOf: frame.samples)
                if let liveDiarizer,
                   diarBuffer.count - lastDiarEnd >= diarStep,
                   diarBuffer.count >= diarWindow {
                    let lo = max(0, diarBuffer.count - diarWindow)
                    let windowSamples = Array(diarBuffer[lo..<diarBuffer.count])
                    let windowStart = samplesToDuration(lo)
                    lastDiarEnd = diarBuffer.count
                    let spans = await liveDiarizer.diarizeWindow(
                        samples: windowSamples, windowStart: windowStart)
                    await diarState.merge(spans)
                }

            case .frame(.mic, let frame):
                micBuffer.append(contentsOf: frame.samples)
                if let micStreamer {
                    for utt in micStreamer.ingest(
                        frame: frame, realTimeElapsed: elapsed) {
                        await sink.appendMicUtterance(utt, realElapsed: elapsed)
                    }
                }

            case .paused(.system):
                // The capture daemon paused (sleep / device change). Annotate
                // the gap in live.md once — driven off the system stream; the
                // mic stream's paired marker is ignored to avoid a double note.
                await sink.appendGap(.paused)

            case .resumed(.system, let gap):
                await sink.appendGap(.resumed(gap))

            case .paused(.mic), .resumed(.mic, _):
                // The mic stream carries the same pause/resume markers; the
                // gap is annotated once, off the system stream above.
                break

            case .ended(.system):
                let elapsedNow = ContinuousClock.now - startWall
                for utt in systemStreamer.finish() {
                    let label = await resolveSystemLabel(
                        for: utt, diarState: diarState, diarizer: liveDiarizer)
                    await sink.appendSystemUtterance(
                        utt, label: label, realElapsed: elapsedNow,
                        isFlush: true)
                }
                systemDone = true

            case .ended(.mic):
                if let micStreamer {
                    let elapsedNow = ContinuousClock.now - startWall
                    for utt in micStreamer.finish() {
                        await sink.appendMicUtterance(
                            utt, realElapsed: elapsedNow, isFlush: true)
                    }
                }
                micDone = true
            }
            if systemDone && micDone { break }
        }

        _ = await readers.value
        // Propagate the language whisper actually detected on the system
        // stream so Output.language reflects reality. Falls back to "en" only
        // when no window was ever decoded (a silent / empty recording).
        await sink.noteSystemLanguage(
            systemStreamer.detectedLanguage ?? "en")

        // Persist the captured audio into the recording folder so a later
        // `pulsartrace refine` of this folder has a system (+ mic) WAV to work
        // from — the canonical 16 kHz mono Int16 storage format (R54e).
        let systemWAV = configuration.recordingFolder
            .appendingPathComponent(RecordingFolder.FileName.audioSystem)
        try? WAVWriter.write(samples: diarBuffer, to: systemWAV)
        if !micBuffer.isEmpty {
            let micWAV = configuration.recordingFolder
                .appendingPathComponent(RecordingFolder.FileName.audioMic)
            try? WAVWriter.write(samples: micBuffer, to: micWAV)
        }

        let stats = await sink.stats()
        return StreamingPipeline.Output(
            liveURL: configuration.liveURL,
            bytesWritten: await writer.bytesWritten,
            utteranceLines: stats.utteranceLines,
            micEchoesDropped: stats.micEchoesDropped,
            medianLagSeconds: stats.medianLagSeconds,
            maxLagSeconds: stats.maxLagSeconds,
            language: stats.systemLanguage)
    }

    /// Read every frame off one `AudioFrameSource` and push tagged items into
    /// the merged stream, finishing with an `.ended` marker. A source is
    /// `Sendable` so this is safe on a child task; the iterator stays local.
    private static func pump(
        _ tag: StreamTag,
        source: any AudioFrameSource,
        into continuation: AsyncStream<MergedItem>.Continuation
    ) async {
        do {
            try await source.start()
            // Iterating `any AudioFrameSource` erases the element to `Any`;
            // recover the concrete `AudioStreamEvent` to dispatch on it.
            for try await event in source {
                switch event as? AudioStreamEvent {
                case .frame(let frame):
                    continuation.yield(.frame(tag, frame))
                case .paused:
                    continuation.yield(.paused(tag))
                case .resumed(let gap):
                    continuation.yield(.resumed(tag, gap))
                case .none:
                    break
                }
            }
        } catch {
            // A source error ends that stream cleanly; the live pass keeps
            // whatever was transcribed so far.
        }
        continuation.yield(.ended(tag))
    }

    /// Resolve the provisional speaker label for a committed system utterance:
    /// the live diarizer's stitched key, optionally upgraded to a library name
    /// (read-only lookup, R18). Always carries the `(provisional)` suffix (R16).
    ///
    /// `internal` (not `private`) so the R18 library-lookup path can be tested
    /// directly — see `LiveRunnerLibraryLookupTests`.
    func resolveSystemLabel(
        for utterance: CommittedUtterance,
        diarState: DiarState,
        diarizer: LiveDiarizer?
    ) async -> String {
        let key = await diarState.dominantKey(
            start: utterance.start, end: utterance.end) ?? "Them"

        // R18: read-only speaker-library lookup. The live pass never writes the
        // library (invariant #5) — `bestMatch` is a pure read. The lookup is
        // scoped to the live diarizer's actual pyannote model revision:
        // `bestMatch` skips speakers recorded under a different revision
        // (Open Question #3), so passing the real revision is what makes R18
        // able to match at all.
        if let library, let diarizer {
            let centroids = await diarizer.centroids()
            let revision = await diarizer.modelRevision()
            if let centroid = centroids[key], !centroid.isEmpty,
               let match = try? await library.bestMatch(
                   for: centroid,
                   modelRevision: revision,
                   threshold: SpeakerLibrary.defaultMatchThreshold) {
                return "\(match.speaker.name) (provisional)"
            }
        }
        return "\(key) (provisional)"
    }

    // MARK: - Helpers

    private func durationToSamples(_ d: Duration) -> Int {
        let ms = Int(d.components.seconds) * 1000
            + Int(d.components.attoseconds / 1_000_000_000_000_000)
        return ms * AudioFormat.sampleRate / 1000
    }
    private func samplesToDuration(_ count: Int) -> Duration {
        .milliseconds(count * 1000 / AudioFormat.sampleRate)
    }
}

/// Accumulates the live diarizer's provisional spans and answers
/// "which provisional speaker dominates this time range?".
actor DiarState {
    private var spans: [LiveSpeakerSpan] = []

    func merge(_ newSpans: [LiveSpeakerSpan]) {
        spans.append(contentsOf: newSpans)
    }

    /// The provisional key whose spans overlap `[start, end]` the most.
    func dominantKey(start: Duration, end: Duration) -> String? {
        let range = start.seconds...max(start.seconds, end.seconds)
        var overlapByKey: [String: Double] = [:]
        for span in spans {
            let lo = max(span.start.seconds, range.lowerBound)
            let hi = min(span.end.seconds, range.upperBound)
            let overlap = max(0, hi - lo)
            if overlap > 0 {
                overlapByKey[span.provisionalKey, default: 0] += overlap
            }
        }
        return overlapByKey.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }?.key
    }
}

/// Serializes all writes to `live.md` and owns the mic-echo dedup state.
///
/// Both streams append through this one actor, so the append-only `live.md`
/// (R36) never sees a half-line from an interleaved write and the dedup state
/// is consistent.
actor LiveSink {
    private let writer: LiveMarkdownWriter
    private let recordingStart: Date
    private var dedup = MicEchoDedup()
    private var utteranceLines = 0
    private var micEchoesDropped = 0
    /// Lag samples for mid-stream commits only (the end-of-stream flush is
    /// excluded — R10 is about live consumption, and the flush decodes the
    /// whole tail at once which is not representative of in-call latency).
    private var lagSamples: [Double] = []
    private var systemLanguage = "en"

    struct Stats: Sendable {
        let utteranceLines: Int
        let micEchoesDropped: Int
        /// Median live lag in seconds across mid-stream commits (R10).
        let medianLagSeconds: Double
        /// Worst mid-stream lag observed.
        let maxLagSeconds: Double
        let systemLanguage: String
    }

    init(writer: LiveMarkdownWriter, recordingStart: Date) {
        self.writer = writer
        self.recordingStart = recordingStart
    }

    /// Append a system-stream utterance with its provisional label (R14, R16).
    ///
    /// `isFlush` marks the end-of-stream flush — its lag is not counted toward
    /// the R10 median (it decodes the whole tail at once).
    func appendSystemUtterance(
        _ utterance: CommittedUtterance,
        label: String,
        realElapsed: Duration,
        isFlush: Bool = false
    ) async {
        dedup.noteSystemUtterance(
            text: utterance.text, start: utterance.start, end: utterance.end)
        await append(
            utterance, label: label, realElapsed: realElapsed, isFlush: isFlush)
    }

    /// Append a mic-stream utterance — always `You` (R17). Dropped when it is a
    /// mic-echo of a recent system utterance (R19).
    func appendMicUtterance(
        _ utterance: CommittedUtterance,
        realElapsed: Duration,
        isFlush: Bool = false
    ) async {
        if dedup.isMicEcho(
            text: utterance.text,
            start: utterance.start,
            end: utterance.end) {
            micEchoesDropped += 1
            return
        }
        await append(
            utterance, label: "You", realElapsed: realElapsed, isFlush: isFlush)
    }

    /// Append a capture pause/resume gap annotation to `live.md` (R7). A
    /// failed append must not crash the live pass.
    func appendGap(_ kind: LiveMarkdownWriter.GapKind) async {
        do {
            try await writer.appendGapAnnotation(kind)
        } catch {
            // An annotation failure is non-fatal — the live pass continues.
        }
    }

    func noteSystemLanguage(_ language: String) {
        systemLanguage = language
    }

    func stats() -> Stats {
        let median: Double
        if lagSamples.isEmpty {
            median = 0
        } else {
            let sorted = lagSamples.sorted()
            median = sorted[sorted.count / 2]
        }
        return Stats(
            utteranceLines: utteranceLines,
            micEchoesDropped: micEchoesDropped,
            medianLagSeconds: median,
            maxLagSeconds: lagSamples.max() ?? 0,
            systemLanguage: systemLanguage)
    }

    private func append(
        _ utterance: CommittedUtterance,
        label: String,
        realElapsed: Duration,
        isFlush: Bool
    ) async {
        // R10 lag: how far behind real time the utterance's end is at commit.
        // The end-of-stream flush is excluded — it is not live latency.
        if !isFlush {
            let lag = max(0, realElapsed.seconds - utterance.end.seconds)
            lagSamples.append(lag)
        }
        do {
            try await writer.appendUtterance(
                offset: utterance.start,
                speakerLabel: label,
                text: utterance.text)
            utteranceLines += 1
        } catch {
            // A failed append must not crash the live pass.
        }
    }
}
