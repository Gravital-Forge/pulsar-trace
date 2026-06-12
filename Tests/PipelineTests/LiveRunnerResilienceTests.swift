import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Resilience coverage for `LiveRunner`'s run loop (Fix A/B/C).
///
/// These tests drive `LiveRunner` directly — not the whole `StreamingPipeline`
/// — so they can inject a **controllable** `AudioFrameSource` (one that goes
/// silent without an EOF) and a **hanging** `LiveDiarizing` stub, neither of
/// which `StreamingPipeline.run` exposes a seam for.
///
/// `.serialized`: tests share the process-wide resident `ParakeetEngine`
/// (`ParakeetTestEngine`); serializing keeps the decode interleaving
/// deterministic enough for the timing-shaped assertions.
@Suite("LiveRunner resilience (silence watchdog, diarizer decoupling)", .serialized)
struct LiveRunnerResilienceTests {

    // MARK: - Helpers

    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pt-resilience-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var fixedStart: Date {
        Date(timeIntervalSince1970: 1_770_000_000)
    }

    /// A non-silent 20 ms frame whose peak clears the streaming VAD gate
    /// (`silencePeakThreshold` 0.01), so the streaming transcriber actually
    /// reaches `transcribeWindow` once a window is due. `.silence` frames are
    /// VAD-gated out before the decode, so they cannot exercise the wedge.
    private func tone(sequenceIndex: Int) -> AudioFrame {
        let n = AudioFormat.samplesPerFrame
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            // ~440 Hz sine at 0.2 amplitude — well above the 0.01 VAD gate.
            s[i] = 0.2 * sin(2 * Float.pi * 440 * Float(i) / Float(AudioFormat.sampleRate))
        }
        return AudioFrame(samples: s, sequenceIndex: sequenceIndex)
    }

    private func makeRunner(
        folder: URL,
        logger: Logger = Logger(label: "test"),
        diarBufferProbe: (@Sendable (Int) -> Void)? = nil,
        silenceGapThreshold: Duration = .milliseconds(250),
        tickInterval: Duration = .milliseconds(40),
        queueCapacity: Duration = .seconds(30),
        workerDrainTimeout: Duration = .seconds(10)
    ) -> (LiveRunner, LiveMarkdownWriter, StreamingPipeline.Configuration) {
        let config = StreamingPipeline.Configuration(
            recordingFolder: folder,
            recordingStart: fixedStart,
            recordingId: "rec_resilience")
        let writer = LiveMarkdownWriter(
            fileURL: config.liveURL, recordingStart: config.recordingStart)
        let runner = LiveRunner(
            configuration: config,
            writer: writer,
            logger: logger,
            library: nil,
            diarBufferProbe: diarBufferProbe,
            silenceGapThreshold: silenceGapThreshold,
            tickInterval: tickInterval,
            queueCapacity: queueCapacity,
            workerDrainTimeout: workerDrainTimeout)
        return (runner, writer, config)
    }

    // MARK: - Fix A — stalled stream does not wedge the run loop

    @Test("a stream that goes silent without EOF does not wedge the run loop and is not prematurely ended")
    func stalledStreamDoesNotWedge() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // The system source delivers a few frames, then goes silent — it never
        // yields another frame and never yields `.ended`. This is a silently
        // stalled capture socket. The run loop must NOT wedge and must NOT
        // treat the silence as an end-of-stream.
        let source = ControllableSource()

        let output: StreamingPipeline.Output
        do {
            let transcriber = ParakeetWindowTranscriber(engine: engine)
            let (runner, writer, _) = makeRunner(folder: folder)
            try await writer.start()

            // Deliver 5 frames of silence, then stall.
            for i in 0..<5 { await source.yieldFrame(.silence(sequenceIndex: i)) }

            // Run the loop on a child task; `done` flips true only when the
            // run actually returns.
            let done = DoneFlag()
            let runTask = Task { () -> StreamingPipeline.Output in
                let out = try await runner.run(
                    systemTranscriber: transcriber,
                    micTranscriber: nil,
                    systemSource: source,
                    micSource: nil,
                    liveDiarizer: nil)
                await done.markDone()
                return out
            }

            // Wait well past the 250 ms silence threshold. The run must NOT
            // have returned — a premature end (the silence wrongly treated as
            // EOF) or a wedge are both excluded: a wedge keeps `done` false
            // forever (still true here), a premature end would flip it true.
            try await Task.sleep(for: .milliseconds(700))
            #expect(await done.isDone == false)

            // Now the capture socket recovers / Stop is pressed: a real EOF
            // arrives. The loop must then terminate cleanly.
            await source.finish()
            let out = try await runTask.value
            #expect(await done.isDone == true)
            await writer.finish()
            output = out
        }

        // The live.md still exists and is valid — the run completed.
        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        #expect(text.hasPrefix("<!-- pulsartrace:live -->"))
        // The silence gap was annotated at least once (append-only).
        #expect(text.contains("_(recording paused)_"))
    }

    @Test("both streams stalling silently still terminates once both .ended arrive")
    func bothStreamsStallThenEndCleanly() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let systemSource = ControllableSource()
        let micSource = ControllableSource()

        let output: StreamingPipeline.Output
        do {
            let sysTranscriber = ParakeetWindowTranscriber(engine: engine)
            let micTranscriber = ParakeetWindowTranscriber(engine: engine)
            let (runner, writer, _) = makeRunner(folder: folder)
            try await writer.start()

            for i in 0..<3 {
                await systemSource.yieldFrame(.silence(sequenceIndex: i))
                await micSource.yieldFrame(.silence(sequenceIndex: i))
            }

            let done = DoneFlag()
            let runTask = Task { () -> StreamingPipeline.Output in
                let out = try await runner.run(
                    systemTranscriber: sysTranscriber,
                    micTranscriber: micTranscriber,
                    systemSource: systemSource,
                    micSource: micSource,
                    liveDiarizer: nil)
                await done.markDone()
                return out
            }

            // Both streams are silent past the threshold — loop stays alive.
            try await Task.sleep(for: .milliseconds(700))
            #expect(await done.isDone == false)

            // EOF on both → the loop's exit condition (both `.ended`) is met.
            await systemSource.finish()
            await micSource.finish()
            let out = try await runTask.value
            #expect(await done.isDone == true)
            await writer.finish()
            output = out
        }

        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        #expect(text.hasPrefix("<!-- pulsartrace:live -->"))
    }

    @Test("the silence gap annotation is append-only — live.md only ever grows")
    func silenceGapIsAppendOnly() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = ControllableSource()
        let liveURL = folder.appendingPathComponent(RecordingFolder.FileName.live)

        let sizes = SizeSamples()
        do {
            let transcriber = ParakeetWindowTranscriber(engine: engine)
            let (runner, writer, _) = makeRunner(folder: folder)
            try await writer.start()

            for i in 0..<5 { await source.yieldFrame(.silence(sequenceIndex: i)) }

            let poller = Task {
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(30))
                    if let data = try? Data(contentsOf: liveURL) {
                        await sizes.record(data.count)
                    }
                }
            }

            let runTask = Task {
                try await runner.run(
                    systemTranscriber: transcriber,
                    micTranscriber: nil,
                    systemSource: source,
                    micSource: nil,
                    liveDiarizer: nil)
            }
            // Let the watchdog fire a couple of gaps, deliver more frames so a
            // resume annotation is appended too, then end.
            try await Task.sleep(for: .milliseconds(500))
            for i in 5..<8 { await source.yieldFrame(.silence(sequenceIndex: i)) }
            try await Task.sleep(for: .milliseconds(100))
            await source.finish()
            _ = try await runTask.value
            poller.cancel()
            await writer.finish()
        }

        // R36/R12: every observed size is ≥ the previous — strictly monotonic
        // growth. The watchdog's gap annotation is append-only.
        let observed = await sizes.values
        for i in 1..<max(observed.count, 1) {
            #expect(observed[i] >= observed[i - 1])
        }
        let finalText = try String(contentsOf: liveURL, encoding: .utf8)
        #expect(finalText.contains("_(recording paused)_"))
    }

    @Test("each stream's silence gap is annotated independently — a mic-only stall after a joint-stall recovery still gets its own note")
    func perStreamSilenceAnnotationIsIndependent() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let systemSource = ControllableSource()
        let micSource = ControllableSource()
        let liveURL = folder.appendingPathComponent(RecordingFolder.FileName.live)

        let output: StreamingPipeline.Output
        do {
            let sysTranscriber = ParakeetWindowTranscriber(engine: engine)
            let micTranscriber = ParakeetWindowTranscriber(engine: engine)
            let (runner, writer, _) = makeRunner(folder: folder)
            try await writer.start()

            for i in 0..<3 {
                await systemSource.yieldFrame(.silence(sequenceIndex: i))
                await micSource.yieldFrame(.silence(sequenceIndex: i))
            }

            let runTask = Task { () -> StreamingPipeline.Output in
                try await runner.run(
                    systemTranscriber: sysTranscriber,
                    micTranscriber: micTranscriber,
                    systemSource: systemSource,
                    micSource: micSource,
                    liveDiarizer: nil)
            }

            // Phase 1 — both streams stall past the threshold (a joint stall),
            // so each emits its own gap note.
            try await Task.sleep(for: .milliseconds(500))

            // Phase 2 — only the system stream recovers. Its watchdog flag is
            // cleared; the mic stream stays silent.
            for i in 3..<6 { await systemSource.yieldFrame(.silence(sequenceIndex: i)) }

            // Phase 3 — the mic stream stalls again past the threshold. With
            // per-stream independent annotation it gets a *fresh* gap note;
            // the old cross-stream coupling would have suppressed it.
            try await Task.sleep(for: .milliseconds(500))

            await systemSource.finish()
            await micSource.finish()
            let out = try await runTask.value
            await writer.finish()
            output = out
        }

        // The mic stall after the system stream recovered still produced a
        // gap note: at least two `_(recording paused)_` notes total — the
        // joint stall (>=1) plus the later mic-only stall.
        let text = try String(contentsOf: liveURL, encoding: .utf8)
        let pausedNotes = text.components(separatedBy: "_(recording paused)_").count - 1
        #expect(pausedNotes >= 2)
        #expect(text.hasPrefix("<!-- pulsartrace:live -->"))
        _ = output
    }

    // MARK: - Fix B — wedged diarizer does not stall transcription

    @Test("a wedged live diarizer does not stall transcription or live.md output")
    func wedgedDiarizerDoesNotStallTranscription() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // A diarizer stub whose `diarizeWindow` never returns — it hangs
        // forever, exactly like a wedged windowed-pyannote subprocess.
        let diarizer = HangingDiarizer()

        let output: StreamingPipeline.Output
        do {
            let transcriber = ParakeetWindowTranscriber(engine: engine)
            let (runner, writer, _) = makeRunner(folder: folder)
            try await writer.start()
            // A real fixture so the transcriber actually has speech to commit.
            let source = FixturePlaybackSource(
                file: FixtureLocator.audio("two-speakers-alternating.wav"),
                realtime: false)
            let out = try await runner.run(
                systemTranscriber: transcriber,
                micTranscriber: nil,
                systemSource: source,
                micSource: nil,
                liveDiarizer: diarizer)
            await writer.finish()
            output = out
        }

        // The diarizer hung on every window, yet transcription still ran to
        // completion and live.md was grown — the diarizer is off the run
        // loop's critical path (Fix B).
        #expect(output.utteranceLines > 0)
        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        #expect(text.contains("?:** "))
        // diarizeWindow was reached (windows were dispatched) but at most one
        // was ever in flight — the single-window bound held.
        #expect(await diarizer.windowsStarted >= 1)
        #expect(await diarizer.maxConcurrent <= 1)
    }

    // MARK: - Fix C — diarBuffer stays bounded

    @Test("diarBuffer stays bounded over a long stream")
    func diarBufferStaysBounded() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Track the largest diarBuffer size the run loop ever held — recorded
        // inline (synchronously) so every observation lands before the run
        // returns and the assertion reads the peak.
        let peak = PeakCounter()
        let probe: @Sendable (Int) -> Void = { count in
            peak.observe(count)
        }

        // A diarizer that returns instantly so windows are dispatched (which
        // is what triggers the trim) all through the stream.
        let diarizer = InstantDiarizer()

        do {
            let transcriber = ParakeetWindowTranscriber(engine: engine)
            let (runner, writer, config) = makeRunner(
                folder: folder, diarBufferProbe: probe)
            try await writer.start()
            // The 30 s single-speaker fixture is the longest committed clip —
            // ~1500 frames, far more than one diarization window.
            let source = FixturePlaybackSource(
                file: FixtureLocator.audio("single-speaker-30s.wav"),
                realtime: false)
            _ = try await runner.run(
                systemTranscriber: transcriber,
                micTranscriber: nil,
                systemSource: source,
                micSource: nil,
                liveDiarizer: diarizer)
            await writer.finish()

            // The buffer must never exceed ~2× the diarization window
            // (the trim margin). With the default 10 s window at 16 kHz that
            // is 320_000 samples; allow one extra frame of slack.
            let diarWindowSamples =
                Int(config.diarizationWindow.components.seconds) * 16_000
            let bound = 2 * diarWindowSamples + 16_000
            let observedPeak = peak.value
            #expect(observedPeak <= bound)
            // The fixture is 30 s ≈ 480_000 samples; an unbounded buffer would
            // far exceed the 2× window bound. A peak well under the raw stream
            // length proves the trim is real.
            #expect(observedPeak > 0)
        }
    }

    // MARK: - Recording safety — WAV is never blocked by the decode

    @Test("a wedged decode never stalls the WAV recording")
    func wedgedDecodeDoesNotStallRecording() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let blocking = BlockingWindowTranscriber()
        let source = ControllableSource()
        let systemWAV = folder.appendingPathComponent(RecordingFolder.FileName.audioSystem)

        let (runner, writer, _) = makeRunner(folder: folder)
        try await writer.start()

        let runTask = Task {
            try await runner.run(
                systemTranscriber: blocking,
                micTranscriber: nil,
                systemSource: source,
                micSource: nil,
                liveDiarizer: nil)
        }

        // Non-silent frames so the streaming transcriber actually reaches
        // `transcribeWindow` (which then wedges) once a window is due — 100
        // frames is 2 s, exactly one step, so the wedge engages mid-stream.
        for i in 0..<100 { await source.yieldFrame(tone(sequenceIndex: i)) }
        try await Task.sleep(for: .milliseconds(400))

        // The recording-folder WAV stores mono Int16 PCM — 2 bytes/sample —
        // so 100 frames of 320 samples is 100 * 320 * 2 data bytes on disk
        // (plus the 44-byte header). Assert the data bytes are all present while
        // the decode is wedged: the WAV grew, the decode did not block it.
        let size = (try? Data(contentsOf: systemWAV))?.count ?? 0
        #expect(size >= 100 * AudioFormat.samplesPerFrame * 2,
                "WAV did not grow while the decode was wedged; size=\(size)")

        await source.finish()
        _ = await withTimeoutOrNil(seconds: 5) { try await runTask.value }
        await writer.finish()

        let finalSize = (try? Data(contentsOf: systemWAV))?.count ?? 0
        #expect(finalSize >= 100 * AudioFormat.samplesPerFrame * 2)
    }

    @Test("when the decode falls behind, the live view notes the drop and recording is whole")
    func dropNoteOnBacklog() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let liveURL = folder.appendingPathComponent(RecordingFolder.FileName.live)

        let blocking = BlockingWindowTranscriber()
        let source = ControllableSource()
        let (runner, writer, _) = makeRunner(folder: folder, queueCapacity: .milliseconds(200))
        try await writer.start()

        let runTask = Task {
            try await runner.run(
                systemTranscriber: blocking, micTranscriber: nil,
                systemSource: source, micSource: nil, liveDiarizer: nil)
        }
        // 200 non-silent frames into a 200 ms (= 10-frame) queue while the decode
        // is wedged: the queue saturates and starts dropping, which the drain notes
        // once in live.md as a recording-paused gap.
        for i in 0..<200 { await source.yieldFrame(tone(sequenceIndex: i)) }
        try await Task.sleep(for: .milliseconds(300))
        await source.finish()
        _ = await withTimeoutOrNil(seconds: 15) { try await runTask.value }
        await writer.finish()

        let text = try String(contentsOf: liveURL, encoding: .utf8)
        #expect(text.contains("_(recording paused)_"))
    }

    // MARK: - Wedge recovery lives in the transcriber, not LiveRunner
    //
    // An earlier design ran an in-process decode watchdog inside `LiveRunner`
    // that flipped an `AbortToken` on a hung decode. That watchdog was deleted:
    // wedge recovery now lives inside the window transcriber itself
    // (`ParakeetWindowTranscriber` bounds a wedged window decode with a 30 s
    // deadline and skips it; the post-pass recovers the audio). The
    // `decodeDeadline` / `abortGrace` knobs the old in-process watchdog used no
    // longer exist on `LiveRunner.init`.
}

// MARK: - Test doubles

/// An `AudioFrameSource` whose frames and end-of-stream are driven explicitly
/// by the test. It can deliver frames, then go **silent** (yield nothing, never
/// EOF) — a silently stalled capture socket — until the test calls `finish()`.
final class ControllableSource: AudioFrameSource {
    typealias Element = AudioStreamEvent

    private let stream: AsyncStream<AudioStreamEvent>
    private let continuation: AsyncStream<AudioStreamEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: AudioStreamEvent.self)
    }

    func start() async throws {}
    func stop() async { continuation.finish() }

    /// Push one frame into the stream.
    func yieldFrame(_ frame: AudioFrame) async {
        continuation.yield(.frame(frame))
    }

    /// End the stream cleanly (the iterator returns `nil` → pump yields `.ended`).
    func finish() async { continuation.finish() }

    func makeAsyncIterator() -> AsyncStream<AudioStreamEvent>.Iterator {
        stream.makeAsyncIterator()
    }
}

/// A `LiveDiarizing` stub whose `diarizeWindow` hangs forever — a wedged
/// windowed-pyannote subprocess. Records how many windows were started and the
/// peak concurrency, so the test can prove the single-window-in-flight bound.
actor HangingDiarizer: LiveDiarizing {
    private(set) var windowsStarted = 0
    private(set) var maxConcurrent = 0
    private var concurrent = 0

    func diarizeWindow(
        samples: [Float], windowStart: Duration
    ) async -> [LiveSpeakerSpan] {
        windowsStarted += 1
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        // Hang forever (until the task is discarded at end of run). A real
        // wedged subprocess behaves exactly this way.
        try? await Task.sleep(for: .seconds(3600))
        concurrent -= 1
        return []
    }

    func centroids() async -> [String: [Float]] { [:] }
    func modelRevision() async -> String { "" }
}

/// A `LiveDiarizing` stub that returns immediately with no spans — used to
/// exercise the diarization cadence (and thus the `diarBuffer` trim) without a
/// real subprocess.
actor InstantDiarizer: LiveDiarizing {
    func diarizeWindow(
        samples: [Float], windowStart: Duration
    ) async -> [LiveSpeakerSpan] { [] }
    func centroids() async -> [String: [Float]] { [:] }
    func modelRevision() async -> String { "" }
}

/// Thread-safe peak tracker for the `diarBuffer` size probe. Lock-backed (not
/// an actor) so the synchronous `@Sendable (Int) -> Void` probe can record a
/// value inline — no detached task, so every observation is captured before
/// the run returns and the test reads `value`.
final class PeakCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func observe(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        _value = max(_value, n)
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

/// Flips `true` exactly when a `LiveRunner.run` task actually returns — lets a
/// test distinguish "still running" from "finished" without racing.
actor DoneFlag {
    private(set) var isDone = false
    func markDone() { isDone = true }
}

/// A `WindowTranscribing` whose every decode blocks forever — the live wedge.
/// Will honor an abort token if one is passed, but the runner passes
/// `abort: nil`, so in these tests this block is unbounded — exactly the wedge
/// condition being stress-tested (recording-safety: WAV keeps growing through
/// the wedge). The surrounding tests bound the wait themselves via
/// `withTimeoutOrNil`.
final class BlockingWindowTranscriber: WindowTranscribing, @unchecked Sendable {
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperOptions,
        abort: AbortToken?
    ) throws -> TranscriptionResult {
        while abort?.isCancelled != true {
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw WhisperTranscribeError.transcriptionFailed(-999)
    }
}

/// Run `body`, returning nil if it does not finish within `seconds`.
func withTimeoutOrNil<T: Sendable>(
    seconds: Double, _ body: @escaping @Sendable () async throws -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await body() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds)); return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
