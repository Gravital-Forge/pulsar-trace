import Foundation
import Logging

/// Drives the live pass's streams and turns committed utterances into
/// append-only `live.md` lines. The execution core behind
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
    /// (capture daemon sleep/wake), or an end marker.
    enum MergedItem: Sendable {
        case frame(StreamTag, AudioFrame)
        /// The stream paused (capture daemon: system sleep / device change).
        case paused(StreamTag)
        /// The stream resumed; carries which one and the paused gap.
        case resumed(StreamTag, Duration)
        /// A stream ended; carries which one.
        case ended(StreamTag)
        /// A periodic heartbeat from the ticker child task (~1 Hz). Carries no
        /// stream — it drives the per-stream silence watchdog (Fix A) and keeps
        /// the run loop alive even when both capture sockets go silently quiet.
        case tick
    }

    /// A stream that goes silent for longer than this — delivering neither
    /// frames nor `.ended` — has its gap annotated once in `live.md` (Fix A).
    ///
    /// Chosen comfortably longer than the capture daemon's own 6 s
    /// stall-restart so the daemon's auto-restart is given a chance to recover
    /// the socket before the live pass annotates a visible gap. Tests inject a
    /// far shorter value via the `LiveRunner` initializer.
    static let defaultSilenceGapThreshold: Duration = .seconds(20)

    /// The ticker child task's heartbeat interval.
    static let defaultTickInterval: Duration = .seconds(1)

    /// Phase-tracker heartbeat cadence (`LiveRunnerPhaseTracker.runHeartbeat`).
    /// Diagnostic only — picks up a wedged run loop within one tick.
    static let defaultPhaseHeartbeatInterval: Duration = .seconds(2)

    /// Phase-tracker threshold — log when the current phase has been active
    /// at least this long. Matches the heartbeat cadence so a wedged phase
    /// reports on the first tick after it crosses 2 s.
    static let defaultPhaseHeartbeatThreshold: Duration = .seconds(2)

    private let configuration: StreamingPipeline.Configuration
    private let writer: LiveMarkdownWriter
    private let logger: Logger
    private let library: SpeakerLibrary?
    /// Test hook: invoked with `diarBuffer.count` after every system frame
    /// (Fix C coverage — assert the buffer stays bounded over a long stream).
    /// `nil` in production.
    private let diarBufferProbe: (@Sendable (Int) -> Void)?
    /// Per-stream silence-watchdog threshold (Fix A). Defaults to the
    /// production `defaultSilenceGapThreshold`; tests inject a short value.
    private let silenceGapThreshold: Duration
    /// Ticker heartbeat interval. Defaults to `defaultTickInterval`.
    private let tickInterval: Duration
    /// Phase-tracker heartbeat interval. Defaults to
    /// `defaultPhaseHeartbeatInterval`. Tests inject a short value.
    private let phaseHeartbeatInterval: Duration
    /// Phase-tracker threshold. Defaults to `defaultPhaseHeartbeatThreshold`.
    private let phaseHeartbeatThreshold: Duration

    init(
        configuration: StreamingPipeline.Configuration,
        writer: LiveMarkdownWriter,
        logger: Logger,
        library: SpeakerLibrary?,
        diarBufferProbe: (@Sendable (Int) -> Void)? = nil,
        silenceGapThreshold: Duration = LiveRunner.defaultSilenceGapThreshold,
        tickInterval: Duration = LiveRunner.defaultTickInterval,
        phaseHeartbeatInterval: Duration = LiveRunner.defaultPhaseHeartbeatInterval,
        phaseHeartbeatThreshold: Duration = LiveRunner.defaultPhaseHeartbeatThreshold
    ) {
        self.configuration = configuration
        self.writer = writer
        self.logger = logger
        self.library = library
        self.diarBufferProbe = diarBufferProbe
        self.silenceGapThreshold = silenceGapThreshold
        self.tickInterval = tickInterval
        self.phaseHeartbeatInterval = phaseHeartbeatInterval
        self.phaseHeartbeatThreshold = phaseHeartbeatThreshold
    }

    func run(
        systemTranscriber: any WindowTranscribing,
        micTranscriber: (any WindowTranscribing)?,
        systemSource: some AudioFrameSource,
        micSource: (any AudioFrameSource)?,
        liveDiarizer: (any LiveDiarizing)?
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

        // The pumps and the ticker run as siblings, but they have different
        // lifetimes: the pumps drive `continuation.finish()`, the ticker must
        // *not*. So the ticker runs in its own inner group that is cancelled
        // the instant both pumps return — `continuation.finish()` is then
        // reached immediately and a normal end is never delayed by the ~1 s
        // tick cadence (Fix A).
        let pumpCount = micSource != nil ? 2 : 1
        let readers = Task { [systemSource] in
            await withTaskGroup(of: Void.self) { group in
                await withTaskGroup(of: Void.self) { inner in
                    inner.addTask { [self] in
                        await self.ticker(into: continuation)
                    }
                    group.addTask { [continuation] in
                        await Self.pump(.system, source: systemSource,
                                        into: continuation)
                    }
                    if let micSource {
                        group.addTask { [continuation] in
                            await Self.pump(.mic, source: micSource,
                                            into: continuation)
                        }
                    }
                    // Wait for exactly the pumps, then cancel the ticker.
                    for _ in 0..<pumpCount { _ = await group.next() }
                    inner.cancelAll()
                }
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

        // The full system + mic audio is streamed straight to disk as frames
        // arrive (see `systemWAVWriter` / `micWAVWriter` below) so a crash mid
        // recording still leaves a recording folder a later `pulsartrace
        // refine` can consume. `diarBuffer` is kept only as the live-diarizer's
        // window source — it no longer backs the WAV.
        //
        // Fix C: `diarBuffer` is **bounded**. The diarizer only ever slices its
        // most recent `diarWindow` samples, so after each window is dispatched
        // the buffer is trimmed from the front to at most `2 * diarWindow`
        // (a small margin past what the next window needs). `diarBufferBase` is
        // the recording-absolute sample index of `diarBuffer[0]` — mirroring
        // `StreamingTranscriber.bufferBaseSample` — so `windowStart` stays
        // recording-absolute-correct after a trim.
        var diarBuffer: [Float] = []
        var diarBufferBase = 0
        let diarStep = durationToSamples(configuration.diarizationStep)
        let diarWindow = durationToSamples(configuration.diarizationWindow)
        /// Recording-absolute sample count at which the last diarization
        /// window was dispatched (paces the step cadence; survives trims).
        var lastDiarEnd = 0
        let diarState = DiarState()
        /// Bounds outstanding live-diarization work to a single window in
        /// flight (Fix B) and lets the run hand off any in-flight task at exit.
        let diarGate = DiarGate()

        var systemDone = false
        var micDone = !hasMic

        // Fix A — per-stream silence watchdog state. Each stream is watched
        // **independently**: `lastActivity` records the continuous-clock instant
        // the stream last delivered a frame OR a pause/resume marker; on a
        // `.tick` a stream silent past the threshold appends its own gap note
        // exactly once (`gapAnnotated`), and when frames resume on that stream
        // it appends its own resumed note and clears its own flag. There is no
        // cross-stream coupling: if both streams stall at once they each emit a
        // note — `live.md` is append-only and a duplicate cosmetic note is
        // harmless. A `.paused` stream is exempt — its quiet is expected.
        var lastSystemActivity = startWall
        var lastMicActivity = startWall
        var systemGapAnnotated = false
        var micGapAnnotated = false
        var systemPaused = false
        var micPaused = false

        // --- incremental WAV capture ----------------------------------------
        // Open the recording-folder WAVs up front and stream every frame to
        // them. The header is re-patched after each append, so the file on
        // disk is always a valid WAV reflecting what was captured — even if the
        // engine is killed before the success path below. The system WAV is
        // always written; the mic WAV only when a mic stream exists.
        let systemWAV = configuration.recordingFolder
            .appendingPathComponent(RecordingFolder.FileName.audioSystem)
        let micWAV = configuration.recordingFolder
            .appendingPathComponent(RecordingFolder.FileName.audioMic)
        let systemWAVWriter = try StreamingWAVWriter(url: systemWAV)
        let micWAVWriter = micSource != nil
            ? try StreamingWAVWriter(url: micWAV)
            : nil

        // Finalize both WAVs on *every* exit from `run` — the normal end, a
        // thrown error, or task cancellation. `finalize()` is idempotent, so a
        // `defer` is the simplest guarantee that the recording folder always
        // keeps a valid, refine-able capture; the whole point of streaming the
        // capture to disk.
        defer {
            finalizeWAV(systemWAVWriter, stream: "system")
            finalizeWAV(micWAVWriter, stream: "mic")
        }

        // Recording-absolute sample count fed to the diarizer so far — the
        // diarizer's window is sliced from this, not the trimmed `diarBuffer`.
        var diarTotalSamples: Int { diarBufferBase + diarBuffer.count }

        // --- diagnostic phase tracker + heartbeat ---------------------------
        // Records the current step of the run loop so a background task can
        // log a warning whenever a single phase has been active longer than
        // the threshold — making a wedged `await` (the suspected cause of the
        // 2026-05-20-113001 / 2026-05-21-071823 silent cutoffs at ~17–18 min)
        // visible as a stream of identical log lines with a growing age.
        // Diagnostic only — every `phase.set` is non-suspending and changes
        // no run-loop semantics.
        let phase = LiveRunnerPhaseTracker()
        var frameIdx = 0
        let phaseLogger = self.logger
        let heartbeatInterval = self.phaseHeartbeatInterval
        let heartbeatThreshold = self.phaseHeartbeatThreshold
        let heartbeatTask = Task {
            await phase.runHeartbeat(
                interval: heartbeatInterval,
                threshold: heartbeatThreshold,
                logger: phaseLogger)
        }
        defer { heartbeatTask.cancel() }
        phase.set("loop-start")

        // --- the run loop ---------------------------------------------------
        for await item in merged {
            let elapsed = ContinuousClock.now - startWall
            switch item {
            case .frame(.system, let frame):
                frameIdx += 1
                phase.set("frame-system-received", frameIndex: frameIdx)
                let systemFrameNow = ContinuousClock.now
                if systemGapAnnotated {
                    // Frames are flowing again after an annotated silence gap
                    // on *this* stream. Append a resumed-style note (append-only
                    // — live.md is never rewritten) carrying the real measured
                    // gap, then re-arm the watchdog for this stream.
                    systemGapAnnotated = false
                    phase.set("await-sink-appendGap-system-resumed")
                    await sink.appendGap(
                        .resumed(systemFrameNow - lastSystemActivity))
                }
                lastSystemActivity = systemFrameNow
                phase.set("wav-append-system")
                appendToWAV(systemWAVWriter, frame.samples, stream: "system")
                phase.set("whisper-ingest-system")
                for utt in systemStreamer.ingest(
                    frame: frame, realTimeElapsed: elapsed) {
                    phase.set("await-resolveSystemLabel")
                    let label = await resolveSystemLabel(
                        for: utt, diarState: diarState, diarizer: liveDiarizer,
                        phase: phase)
                    phase.set("await-sink-appendSystemUtterance")
                    await sink.appendSystemUtterance(
                        utt, label: label, realElapsed: elapsed)
                }
                // Feed a diarization window on cadence — *off* the run loop's
                // critical path (Fix B). The window samples + windowStart are
                // captured as locals and a detached task runs `diarizeWindow`
                // then `diarState.merge`; the run loop never `await`s the
                // diarizer subprocess. At most one window is in flight — if the
                // previous one has not finished, this window is skipped (live
                // diarization is best-effort/provisional).
                diarBuffer.append(contentsOf: frame.samples)
                if let liveDiarizer,
                   diarTotalSamples - lastDiarEnd >= diarStep,
                   diarTotalSamples >= diarWindow {
                    let loAbs = max(0, diarTotalSamples - diarWindow)
                    let lo = loAbs - diarBufferBase
                    lastDiarEnd = diarTotalSamples
                    phase.set("await-diarGate-tryAcquire")
                    if lo >= 0, lo <= diarBuffer.count,
                       await diarGate.tryAcquire() {
                        // Copy the window out of `diarBuffer` up front: the
                        // detached task owns this independent `[Float]`, so the
                        // run loop's concurrent front-trim of `diarBuffer`
                        // below cannot mutate the in-flight task's samples.
                        let windowSamples = Array(diarBuffer[lo...])
                        let windowStart = samplesToDuration(loAbs)
                        Task.detached {
                            let spans = await liveDiarizer.diarizeWindow(
                                samples: windowSamples,
                                windowStart: windowStart)
                            await diarState.merge(spans)
                            await diarGate.release()
                        }
                    }
                }
                // Fix C: trim `diarBuffer` to its recent tail on *every* system
                // frame — not only on a diarization trigger — so the buffer is
                // held tight at `2 * diarWindow` (it never grows by a whole
                // step between triggers). The diarizer only ever needs the last
                // `diarWindow` samples; `2 * diarWindow` is the safety margin.
                // `diarBufferBase` advances by exactly what is dropped, so the
                // recording-absolute `windowStart`/`lo` above stay correct.
                let diarKeep = 2 * diarWindow
                if diarBuffer.count > diarKeep {
                    let trim = diarBuffer.count - diarKeep
                    diarBuffer.removeFirst(trim)
                    diarBufferBase += trim
                }
                diarBufferProbe?(diarBuffer.count)

            case .frame(.mic, let frame):
                frameIdx += 1
                phase.set("frame-mic-received", frameIndex: frameIdx)
                let micFrameNow = ContinuousClock.now
                if micGapAnnotated {
                    // Frames are flowing again on the mic stream after its own
                    // annotated silence gap — append a resumed note carrying the
                    // real measured gap and re-arm this stream's watchdog.
                    micGapAnnotated = false
                    phase.set("await-sink-appendGap-mic-resumed")
                    await sink.appendGap(.resumed(micFrameNow - lastMicActivity))
                }
                lastMicActivity = micFrameNow
                phase.set("wav-append-mic")
                appendToWAV(micWAVWriter, frame.samples, stream: "mic")
                if let micStreamer {
                    phase.set("whisper-ingest-mic")
                    for utt in micStreamer.ingest(
                        frame: frame, realTimeElapsed: elapsed) {
                        phase.set("await-sink-appendMicUtterance")
                        await sink.appendMicUtterance(utt, realElapsed: elapsed)
                    }
                }

            case .paused(.system):
                // The capture daemon paused (sleep / device change). Annotate
                // the gap in live.md once — driven off the system stream; the
                // mic stream's paired marker is ignored to avoid a double note.
                systemPaused = true
                lastSystemActivity = ContinuousClock.now
                phase.set("await-sink-appendGap-paused-system")
                await sink.appendGap(.paused)

            case .resumed(.system, let gap):
                systemPaused = false
                lastSystemActivity = ContinuousClock.now
                phase.set("await-sink-appendGap-resumed-system")
                await sink.appendGap(.resumed(gap))

            case .paused(.mic):
                // The mic stream carries the same pause/resume markers; the
                // gap is annotated once, off the system stream above. The
                // marker still counts as activity for the mic watchdog.
                micPaused = true
                lastMicActivity = ContinuousClock.now

            case .resumed(.mic, _):
                micPaused = false
                lastMicActivity = ContinuousClock.now

            case .tick:
                // Fix A — per-stream silence watchdog. The tick keeps the run
                // loop alive when both capture sockets stall silently (a
                // wedged socket delivers neither frames nor `.ended`). A
                // silence gap is purely an annotation: it NEVER sets
                // `systemDone`/`micDone` and NEVER breaks the loop.
                //
                // Each stream is watched independently — when it goes silent
                // past the threshold it appends its own `_(recording paused)_`
                // note exactly once. If both streams stall at the same time
                // two notes are emitted; that is acceptable (append-only,
                // cosmetic) and keeps the logic per-stream and clear.
                let now = ContinuousClock.now
                if !systemDone, !systemPaused, !systemGapAnnotated,
                   now - lastSystemActivity >= silenceGapThreshold {
                    systemGapAnnotated = true
                    phase.set("await-sink-appendGap-tick-system")
                    await sink.appendGap(.paused)
                }
                if hasMic, !micDone, !micPaused, !micGapAnnotated,
                   now - lastMicActivity >= silenceGapThreshold {
                    micGapAnnotated = true
                    phase.set("await-sink-appendGap-tick-mic")
                    await sink.appendGap(.paused)
                }

            case .ended(.system):
                phase.set("ended-system")
                let elapsedNow = ContinuousClock.now - startWall
                for utt in systemStreamer.finish() {
                    phase.set("await-resolveSystemLabel-flush")
                    let label = await resolveSystemLabel(
                        for: utt, diarState: diarState, diarizer: liveDiarizer,
                        phase: phase)
                    phase.set("await-sink-appendSystemUtterance-flush")
                    await sink.appendSystemUtterance(
                        utt, label: label, realElapsed: elapsedNow,
                        isFlush: true)
                }
                systemDone = true

            case .ended(.mic):
                phase.set("ended-mic")
                if let micStreamer {
                    let elapsedNow = ContinuousClock.now - startWall
                    for utt in micStreamer.finish() {
                        phase.set("await-sink-appendMicUtterance-flush")
                        await sink.appendMicUtterance(
                            utt, realElapsed: elapsedNow, isFlush: true)
                    }
                }
                micDone = true
            }
            // The exit condition is *exactly* "both streams `.ended`". A
            // silence gap never reaches here as a done flag.
            if systemDone && micDone { break }
            phase.set("idle-awaiting-next-item")
        }

        // Fix B: hand off any in-flight diarization task before returning —
        // bounded, so a wedged diarizer cannot make the run hang on exit.
        phase.set("await-diarGate-drain")
        await diarGate.drain(timeout: .seconds(2))
        phase.set("await-readers-value")
        _ = await readers.value
        // Propagate the language whisper actually detected on the system
        // stream so Output.language reflects reality. Falls back to "en" only
        // when no window was ever decoded (a silent / empty recording).
        phase.set("await-sink-noteSystemLanguage")
        await sink.noteSystemLanguage(
            systemStreamer.detectedLanguage ?? "en")

        phase.set("await-sink-stats")
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

    /// Yield a `.tick` into the merged stream roughly once per `tickInterval`
    /// until cancelled (Fix A). The tick is what keeps the run loop alive when
    /// a capture socket stalls silently — it drives the per-stream silence
    /// watchdog. It is cancelled the moment both pumps finish, so it never
    /// delays a normal end and `continuation.finish()` is always reached.
    private func ticker(
        into continuation: AsyncStream<MergedItem>.Continuation
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: tickInterval)
            } catch {
                break   // cancelled
            }
            continuation.yield(.tick)
        }
    }

    /// Resolve the provisional speaker label for a committed system utterance:
    /// the live diarizer's stitched key, optionally upgraded to a library name
    /// (read-only lookup, R18). Always carries the `(provisional)` suffix (R16).
    ///
    /// `internal` (not `private`) so the R18 library-lookup path can be tested
    /// directly — see `LiveRunnerLibraryLookupTests`.
    ///
    /// `phase` is an optional diagnostic tracker — when supplied (production
    /// callers do, tests typically don't) the inner `await`s update phase
    /// strings so a wedge inside the library / diarizer-actor lookup chain is
    /// observable in the heartbeat log.
    func resolveSystemLabel(
        for utterance: CommittedUtterance,
        diarState: DiarState,
        diarizer: (any LiveDiarizing)?,
        phase: LiveRunnerPhaseTracker? = nil
    ) async -> String {
        phase?.set("await-diarState-dominantKey")
        let key = await diarState.dominantKey(
            start: utterance.start, end: utterance.end) ?? "Them"

        // R18: read-only speaker-library lookup. The live pass never writes the
        // library (invariant #5) — `bestMatch` is a pure read. The lookup is
        // scoped to the live diarizer's actual pyannote model revision:
        // `bestMatch` skips speakers recorded under a different revision
        // (Open Question #3), so passing the real revision is what makes R18
        // able to match at all.
        if let library, let diarizer {
            phase?.set("await-diarizer-centroids")
            let centroids = await diarizer.centroids()
            phase?.set("await-diarizer-modelRevision")
            let revision = await diarizer.modelRevision()
            if let centroid = centroids[key], !centroid.isEmpty {
                phase?.set("await-library-bestMatch")
                if let match = try? await library.bestMatch(
                       for: centroid,
                       modelRevision: revision,
                       threshold: SpeakerLibrary.defaultMatchThreshold) {
                    return "\(match.speaker.name) (provisional)"
                }
            }
        }
        return "\(key) (provisional)"
    }

    // MARK: - Helpers

    /// Append a frame's samples to a streaming WAV writer. A write failure is
    /// non-fatal — the live pass must keep transcribing — but it is logged as
    /// an error so a lost-capture problem is visible (no silent `try?`).
    private func appendToWAV(
        _ writer: StreamingWAVWriter?, _ samples: [Float], stream: String
    ) {
        guard let writer else { return }
        do {
            try writer.append(samples)
        } catch {
            logger.error(
                "streaming WAV append failed",
                metadata: ["stream": "\(stream)", "error": "\(error)"])
        }
    }

    /// Finalize a streaming WAV writer (idempotent). A failure here only means
    /// the last header patch / close did not complete — logged, never fatal.
    private func finalizeWAV(_ writer: StreamingWAVWriter?, stream: String) {
        guard let writer else { return }
        do {
            try writer.finalize()
        } catch {
            logger.error(
                "streaming WAV finalize failed",
                metadata: ["stream": "\(stream)", "error": "\(error)"])
        }
    }

    private func durationToSamples(_ d: Duration) -> Int {
        let ms = Int(d.components.seconds) * 1000
            + Int(d.components.attoseconds / 1_000_000_000_000_000)
        return ms * AudioFormat.sampleRate / 1000
    }
    private func samplesToDuration(_ count: Int) -> Duration {
        .milliseconds(count * 1000 / AudioFormat.sampleRate)
    }
}

/// Bounds the outstanding live-diarization work to a single window in flight
/// (Fix B).
///
/// The run loop dispatches each due diarization window to a detached task so a
/// wedged diarizer subprocess cannot stall transcription or `live.md`. Without
/// a bound, a slow diarizer would let detached tasks (and their captured window
/// samples) pile up unboundedly. `DiarGate` is the bound: `tryAcquire()`
/// succeeds only when no window is in flight; the detached task `release()`s
/// when it finishes. A window that cannot acquire is simply skipped — live
/// diarization is best-effort/provisional and the post-pass is the source of
/// truth.
actor DiarGate {
    private var inFlight = false

    /// Take the single in-flight slot. `true` → caller owns it and must
    /// eventually `release()`; `false` → a window is already in flight, skip.
    func tryAcquire() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    /// Release the in-flight slot (called by the detached diar task on finish).
    func release() { inFlight = false }

    /// At end of run, wait — bounded by `timeout` — for any in-flight window to
    /// finish so a detached diar task does not outlive the run. A wedged
    /// diarizer simply times out here; the run still returns.
    ///
    /// The poll loop is cancellation-aware: `Task.isCancelled` is part of the
    /// loop condition, so a cancelled task exits promptly instead of swallowing
    /// the `CancellationError` from `Task.sleep` and spinning to the deadline.
    func drain(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while inFlight && ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
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
