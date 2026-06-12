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
/// real-time pace. But a window transcriber is not `Sendable` (it drives a
/// resident model), so the transcribers cannot be captured into child
/// tasks. The resolution: the **frame reading** runs on child tasks (an
/// `AudioFrameSource` *is* `Sendable`, only its iterator is not), each feeding
/// a single `AsyncStream` of `(stream, frame)` tuples. The run loop then
/// consumes that merged stream on one task, holding both transcribers as
/// locals — so the decode is only ever touched from one task and `live.md`
/// only ever sees one append at a time.
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
    /// Test hook: invoked with the diar buffer's sample count after every
    /// system frame (Fix C coverage — assert the buffer stays bounded over a
    /// long stream). `nil` in production.
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
    /// Per-stream decode hand-off queue capacity, in audio duration. The drain
    /// drops the oldest frame from the live view (recording unaffected) once a
    /// queue holds more than this much un-decoded audio (Phase 1).
    private let queueCapacity: Duration
    /// Bounded wait on the decode worker at teardown. A wedged decode that
    /// would otherwise outlive the run cannot make the run hang past this —
    /// the recording is already safe on disk regardless. The in-process
    /// transcriber bounds a hung decode earlier still
    /// (`ParakeetWindowTranscriber`'s 30 s deadline skips the window), so the
    /// teardown bound exists only as a defensive cap.
    private let workerDrainTimeout: Duration

    init(
        configuration: StreamingPipeline.Configuration,
        writer: LiveMarkdownWriter,
        logger: Logger,
        library: SpeakerLibrary?,
        diarBufferProbe: (@Sendable (Int) -> Void)? = nil,
        silenceGapThreshold: Duration = LiveRunner.defaultSilenceGapThreshold,
        tickInterval: Duration = LiveRunner.defaultTickInterval,
        phaseHeartbeatInterval: Duration = LiveRunner.defaultPhaseHeartbeatInterval,
        phaseHeartbeatThreshold: Duration = LiveRunner.defaultPhaseHeartbeatThreshold,
        queueCapacity: Duration = .seconds(30),
        workerDrainTimeout: Duration = .seconds(10)
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
        self.queueCapacity = queueCapacity
        self.workerDrainTimeout = workerDrainTimeout
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
        // refine` can consume. `diarBuffers` is kept only as the live-diarizer's
        // window source — it no longer backs the WAV. Cadence gating and the
        // Fix C bounded trim live in `DiarBufferManager`.
        let diarStep = durationToSamples(configuration.diarizationStep)
        let diarWindow = durationToSamples(configuration.diarizationWindow)
        var diarBuffers = DiarBufferManager(
            stepSamples: diarStep, windowSamples: diarWindow)
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

        // --- per-stream decode hand-off queues + worker ---------------------
        // Phase 1: the recording-safe drain (the `for await item in merged`
        // loop below) writes the WAV, feeds diarization, and *enqueues* frames
        // onto bounded per-stream queues — it never runs a decode. A single
        // worker Task owns the (non-Sendable) streamers, drains both queues,
        // and writes committed utterances to the sink. A hung/slow decode can
        // therefore never block the WAV write — the recording is always safe.
        // Wakeup signal: each queue posts on enqueue/finish so the single worker
        // re-checks both queues. AsyncStream's buffering makes lost wakeups
        // impossible (a yield before the next await is retained). Created before
        // the queues so the activity closures can be passed at queue init.
        let (wake, wakeContinuation) = AsyncStream.makeStream(of: Void.self)
        let queueCapacityFrames = max(
            1, durationToSamples(queueCapacity) / AudioFormat.samplesPerFrame)
        let systemQueue = BoundedFrameQueue(
            capacityFrames: queueCapacityFrames,
            onActivity: { wakeContinuation.yield(()) })
        let micQueue: BoundedFrameQueue? = hasMic
            ? BoundedFrameQueue(
                capacityFrames: queueCapacityFrames,
                onActivity: { wakeContinuation.yield(()) })
            : nil

        // The streamers are non-Sendable (`StreamingTranscriber` drives a
        // resident model). Box them so the worker Task can capture them
        // across the Swift 6 concurrency boundary. Safe: the box's contents are
        // ONLY ever touched on the worker task below — nowhere else.
        let streamerBox = StreamerBox(system: systemStreamer, mic: micStreamer)

        // The worker publishes its end-of-stream detected language here when it
        // finishes. Teardown *polls* this (bounded) rather than `await`ing the
        // worker Task — a wedged decode is uncancellable, so structurally
        // awaiting it (e.g. via `withTaskGroup`) would block the run forever.
        // The poll loop is the same cancellation-safe shape as `DiarGate.drain`.
        let workerResult = WorkerLanguageResult()

        // The per-decode watchdog is gone. Wedge recovery now lives **inside**
        // the `WindowTranscribing` conformer: `ParakeetWindowTranscriber`
        // bounds a wedged window decode with a 30 s deadline and skips it —
        // the post-pass recovers the audio (D39).

        // The decode worker: owns the streamers, drains both queues, writes
        // committed utterances to the sink. Never blocks the drain — the queues
        // drop-oldest under backpressure. Publishes the system stream's detected
        // language to `workerResult` at end of stream (teardown polls it).
        //
        // The synchronous decode (`ingest` / `finish`) is offloaded to a
        // background DispatchQueue via `Self.offload` rather than called directly
        // on the worker Task. A decode can block for the transcriber's deadline
        // (`ParakeetWindowTranscriber`'s 30 s window bound). Calling it directly
        // would pin a Swift cooperative-pool thread, which can starve the bounded
        // teardown timeout's own `Task.sleep` (the timer continuation needs a
        // free pool thread). Offloading keeps the worker Task suspended (pool
        // thread free) while the blocking call runs on a dispatch thread — so the
        // teardown timeout always fires and the run always returns. The streamer
        // is only ever touched here (the worker is suspended awaiting the
        // offload), so no concurrent access occurs.
        let worker = Task { [streamerBox] () -> Void in
            var wakeIterator = wake.makeAsyncIterator()
            var systemEnded = false
            var micEnded = (micQueue == nil)

            func drain(
                _ queue: BoundedFrameQueue?, _ streamer: StreamingTranscriber?,
                isMic: Bool
            ) async -> Bool {
                guard let queue, let streamer else { return true }
                while let frame = queue.tryDequeueNonSuspending() {
                    let elapsed = ContinuousClock.now - startWall
                    // Both streams decode in-process via `ParakeetWindowTranscriber`,
                    // which bounds a wedged window with its own 30 s deadline and
                    // skips it — the post-pass recovers the audio. No per-decode
                    // cancellation token is threaded through.
                    let utterances = await Self.offload {
                        streamer.ingest(
                            frame: frame, realTimeElapsed: elapsed)
                    }
                    await workerResult.noteProgress()
                    for utt in utterances {
                        if isMic {
                            await sink.appendMicUtterance(utt, realElapsed: elapsed)
                        } else {
                            let label = await self.resolveSystemLabel(
                                for: utt, diarState: diarState, diarizer: liveDiarizer)
                            await sink.appendSystemUtterance(
                                utt, label: label, realElapsed: elapsed)
                        }
                    }
                }
                if queue.isFinishedAndEmpty {
                    let elapsed = ContinuousClock.now - startWall
                    let utterances = await Self.offload { streamer.finish() }
                    await workerResult.noteProgress()
                    for utt in utterances {
                        if isMic {
                            await sink.appendMicUtterance(
                                utt, realElapsed: elapsed, isFlush: true)
                        } else {
                            let label = await self.resolveSystemLabel(
                                for: utt, diarState: diarState, diarizer: liveDiarizer)
                            await sink.appendSystemUtterance(
                                utt, label: label, realElapsed: elapsed, isFlush: true)
                        }
                    }
                    return true
                }
                return false
            }

            while true {
                if !systemEnded {
                    systemEnded = await drain(
                        systemQueue, streamerBox.system, isMic: false)
                }
                if !micEnded {
                    micEnded = await drain(micQueue, streamerBox.mic, isMic: true)
                }
                if systemEnded && micEnded { break }
                _ = await wakeIterator.next()
            }
            // Publish the detected language and mark the worker finished so the
            // bounded poll in teardown can pick it up without awaiting the Task.
            // No window detected a language → the live pass reports the
            // "no information" contract value. Parakeet has no language-ID
            // head, so this is the steady-state value for the live pass (D39);
            // the refine pass detects/pins the real language.
            await workerResult.finish(
                language: streamerBox.system.detectedLanguage ?? "unknown")
        }

        phase.set("loop-start")

        // --- the run loop ---------------------------------------------------
        // The drain owns the WAV write, diarization, and the per-stream silence
        // watchdog; it never runs a decode. Each `.frame` case is WAV-first,
        // then enqueues onto the worker's queue. Real-time elapsed is computed
        // per-case where needed (the worker computes its own at decode time).
        for await item in merged {
            switch item {
            case .frame(.system, let frame):
                frameIdx += 1
                phase.set("frame-system-received", frameIndex: frameIdx)
                let systemFrameNow = ContinuousClock.now
                // WAV FIRST — the recording must never sit behind anything.
                phase.set("wav-append-system")
                appendToWAV(systemWAVWriter, frame.samples, stream: "system")
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
                // Feed a diarization window on cadence — *off* the run loop's
                // critical path (Fix B). `DiarBufferManager` owns the cadence
                // gating, the window copy (an independent `[Float]` the
                // detached task can safely own), and the Fix C bounded trim.
                // A detached task runs `diarizeWindow` then `diarState.merge`;
                // the run loop never `await`s the diarizer subprocess. At most
                // one window is in flight — if the previous one has not
                // finished, this window is skipped (live diarization is
                // best-effort/provisional).
                if let liveDiarizer {
                    if let req = diarBuffers.append(frame.samples) {
                        phase.set("await-diarGate-tryAcquire")
                        if await diarGate.tryAcquire() {
                            let windowStart = samplesToDuration(req.startSampleIndex)
                            Task.detached {
                                let spans = await liveDiarizer.diarizeWindow(
                                    samples: req.samples, windowStart: windowStart)
                                await diarState.merge(spans)
                                await diarGate.release()
                            }
                        }
                    }
                } else {
                    _ = diarBuffers.append(frame.samples)   // trim behavior unchanged without a diarizer
                }
                diarBufferProbe?(diarBuffers.bufferedSampleCount)
                // Hand off to the decode worker — never blocks; drops oldest if behind.
                phase.set("enqueue-system")
                systemQueue.enqueue(frame)
                await noteDropEdges(systemQueue, stream: "system", sink: sink)

            case .frame(.mic, let frame):
                frameIdx += 1
                phase.set("frame-mic-received", frameIndex: frameIdx)
                let micFrameNow = ContinuousClock.now
                phase.set("wav-append-mic")
                appendToWAV(micWAVWriter, frame.samples, stream: "mic")  // WAV FIRST
                if micGapAnnotated {
                    // Frames are flowing again on the mic stream after its own
                    // annotated silence gap — append a resumed note carrying the
                    // real measured gap and re-arm this stream's watchdog.
                    micGapAnnotated = false
                    phase.set("await-sink-appendGap-mic-resumed")
                    await sink.appendGap(.resumed(micFrameNow - lastMicActivity))
                }
                lastMicActivity = micFrameNow
                if let micQueue {
                    phase.set("enqueue-mic")
                    micQueue.enqueue(frame)
                    await noteDropEdges(micQueue, stream: "mic", sink: sink)
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
                systemQueue.finish()
                systemDone = true

            case .ended(.mic):
                phase.set("ended-mic")
                micQueue?.finish()
                micDone = true
            }
            // The exit condition is *exactly* "both streams `.ended`". A
            // silence gap never reaches here as a done flag.
            if systemDone && micDone { break }
            phase.set("idle-awaiting-next-item")
        }

        // Both streams ended: let the worker drain remaining frames + flush. We
        // *poll* the worker's published result rather than `await worker.value`:
        // a wedged decode is uncancellable, so structurally awaiting the
        // worker (e.g. via `withTaskGroup`) would block the run forever even
        // after `cancel()`. The bound is on *inactivity* — the run stops waiting
        // once the worker has made no progress for `workerDrainTimeout`. The
        // deadline is *armed at teardown start* (`armDeadline()` below) so it
        // measures inactivity since teardown began, not since run-start — a
        // short recording whose single final decode is slow but progressing
        // then gets the full `workerDrainTimeout` of grace. A
        // slow-but-progressing decode (a fast-fed fixture, or the model
        // catching up on a backlog) therefore runs to completion, while a
        // genuinely wedged decode releases the run after the timeout. The poll
        // loop is cancellation-aware (mirrors `DiarGate.drain`) and falls back to
        // "unknown" if the worker never reported a language — Parakeet has no
        // language-ID head, so the language is "unknown" unless a backend
        // surfaces one. The recording is safe on disk regardless.
        phase.set("await-worker")
        await workerResult.armDeadline()
        while !(await workerResult.isFinished), !Task.isCancelled,
              ContinuousClock.now - (await workerResult.lastProgress)
                < workerDrainTimeout {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let detectedLanguage = await workerResult.language ?? "unknown"
        worker.cancel()  // abandon a still-wedged worker; recording is safe

        // Fix B: hand off any in-flight diarization task before returning —
        // bounded, so a wedged diarizer cannot make the run hang on exit.
        phase.set("await-diarGate-drain")
        await diarGate.drain(timeout: .seconds(2))
        phase.set("await-readers-value")
        _ = await readers.value
        // Propagate the language the backend reported for the system stream so
        // Output.language reflects reality — "unknown" under Parakeet, which
        // has no language-ID head, unless a backend surfaces a code.
        phase.set("await-sink-noteSystemLanguage")
        await sink.noteSystemLanguage(detectedLanguage)

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
    /// (read-only lookup, R18). Always carries the `?` provisional suffix (R16).
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
                    return "\(match.speaker.name)?"
                }
            }
        }
        return "\(key)?"
    }

    // MARK: - Helpers

    /// Run a blocking synchronous body on a background dispatch thread and await
    /// its result, suspending the caller (and freeing its Swift cooperative-pool
    /// thread) while the body runs. Used by the decode worker so an unbounded /
    /// wedged decode never pins a pool thread (which would starve the bounded
    /// teardown timeout). The body is only ever invoked from the single worker
    /// task while it is otherwise suspended, so the unchecked-Sendable wrapper is
    /// safe (no concurrent access to the captured streamer).
    private static func offload<T: Sendable>(
        _ body: @escaping () -> T
    ) async -> T {
        // `body` captures the non-Sendable streamer; wrap it so it can cross the
        // continuation boundary. Safe: see the doc comment above.
        let boxed = UncheckedSendableBox(body)
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: boxed.value())
            }
        }
    }

    /// Emit a one-time live.md note when a queue starts dropping, and another
    /// when it catches back up. Best-effort; the only cost on the drain hot path
    /// is a cheap sink append at the rare drop/recover transition.
    private func noteDropEdges(
        _ queue: BoundedFrameQueue, stream: String, sink: LiveSink
    ) async {
        if queue.consumeDropEpisodeStarted() {
            logger.warning("live transcription falling behind; dropping \(stream) audio from the live view (recording unaffected)")
            await sink.appendGap(.paused)
        }
        if queue.consumeCaughtUp() {
            await sink.appendGap(.resumed(.zero))
        }
    }

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

/// Wraps an arbitrary value so it can cross a `Sendable` boundary (e.g. a
/// `withCheckedContinuation` closure) without the compiler proving it. Used by
/// `LiveRunner.offload` to carry a closure that captures the non-`Sendable`
/// streamer onto a dispatch thread; safe because the worker is suspended (no
/// concurrent access) while the offloaded body runs.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A `Sendable` wrapper that lets the non-`Sendable` `StreamingTranscriber`s be
/// captured into the single decode worker `Task` (Swift 6 concurrency). Its
/// contents are ONLY ever touched on the serialized offload path driven by the
/// single worker (the blocking decode runs on a DispatchQueue thread while the
/// worker is suspended), so the unchecked conformance is safe — the streamers
/// are never concurrently accessed.
private final class StreamerBox: @unchecked Sendable {
    let system: StreamingTranscriber
    let mic: StreamingTranscriber?
    init(system: StreamingTranscriber, mic: StreamingTranscriber?) {
        self.system = system
        self.mic = mic
    }
}
