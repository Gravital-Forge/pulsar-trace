import Testing
import Foundation
import Logging
@testable import PulsarTraceEngine

/// Unit coverage of `StreamingTranscriber`'s pure utterance-grouping logic.
/// The whisper-driven streaming behaviour is exercised end-to-end in
/// the Pipeline suite; this covers the deterministic grouping in isolation.
@Suite("Streaming transcriber grouping")
struct StreamingTranscriberUnitTests {

    private func token(_ text: String, startMS: Int, endMS: Int)
        -> LiveAgreementCommitter.Token {
        LiveAgreementCommitter.Token(
            key: LiveAgreementCommitter.normalizationKey(text),
            text: text,
            start: .milliseconds(startMS),
            end: .milliseconds(endMS))
    }

    @Test("a contiguous run of tokens groups into one utterance")
    func contiguousRunIsOneUtterance() {
        let tokens = [
            token("the", startMS: 0, endMS: 300),
            token("auth", startMS: 300, endMS: 600),
            token("flow", startMS: 600, endMS: 900),
        ]
        let out = StreamingTranscriber.groupTokens(tokens, gap: .milliseconds(800))
        #expect(out.count == 1)
        #expect(out[0].text == "the auth flow")
        #expect(out[0].start == .milliseconds(0))
        #expect(out[0].end == .milliseconds(900))
    }

    @Test("a silence gap splits tokens into separate utterances")
    func silenceGapSplits() {
        let tokens = [
            token("hello", startMS: 0, endMS: 400),
            token("there", startMS: 400, endMS: 800),
            // 2s of silence here — exceeds the 800ms gap.
            token("welcome", startMS: 2800, endMS: 3200),
            token("back", startMS: 3200, endMS: 3600),
        ]
        let out = StreamingTranscriber.groupTokens(tokens, gap: .milliseconds(800))
        #expect(out.count == 2)
        #expect(out[0].text == "hello there")
        #expect(out[1].text == "welcome back")
    }

    @Test("empty token list groups to no utterances")
    func emptyGroupsToNothing() {
        let out = StreamingTranscriber.groupTokens([], gap: .milliseconds(800))
        #expect(out.isEmpty)
    }

    @Test("a small gap under the threshold does not split")
    func smallGapDoesNotSplit() {
        let tokens = [
            token("one", startMS: 0, endMS: 300),
            // 500ms gap — under the 800ms threshold.
            token("two", startMS: 800, endMS: 1100),
        ]
        let out = StreamingTranscriber.groupTokens(tokens, gap: .milliseconds(800))
        #expect(out.count == 1)
    }

    // MARK: - Decode-error logging

    /// When the underlying transcriber throws, `runWindow` must log the
    /// actual error — not just "skipping window". Before the 2026-05-27
    /// fix, the catch dropped the error payload, which made the
    /// production wedge that triggered this work undiagnosable: the log
    /// said "streaming window decode failed" with no hint of what
    /// failed underneath. Regression-guard the interpolation.
    @Test("runWindow catch logs the underlying error message, not just 'skipping window'")
    func runWindowLogsUnderlyingError() {
        let throwing = ThrowingWindowTranscriber(
            error: TranscriptionError.modelLoadFailed(
                "spawn failed: subprocess exited 75 before handshake"))
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }
        let runner = StreamingTranscriber(
            transcriber: throwing,
            configuration: .init(
                windowDuration: .milliseconds(20),
                stepInterval: .milliseconds(20),
                silencePeakThreshold: 0.0),
            logger: logger)

        // One non-silent frame is enough — the 20 ms window / 20 ms step
        // configuration above runs a window on the very first frame.
        let nonSilent = AudioFrame(
            samples: [Float](repeating: 0.5, count: AudioFormat.samplesPerFrame),
            sequenceIndex: 0)
        _ = runner.ingest(frame: nonSilent)

        let skipping = capture.messages.filter { $0.contains("skipping window") }
        #expect(skipping.count == 1, "saw: \(capture.messages)")
        let logged = skipping.first ?? ""
        #expect(logged.contains("subprocess exited 75"),
                "expected underlying error in log; got: \(logged)")
    }

    /// Regression for 2026-05-28: when `transcribeWindow` had been
    /// failing during a wedge respawn and real-time was now seconds
    /// ahead of the streamer's accumulated audio, the backpressure
    /// path called `advanceAnchor(to: realSample - windowSamples)` —
    /// `advanceAnchor` clamped that target down to
    /// `recordingSampleCount`, which emptied the sample buffer, and
    /// the next `runWindow` returned early via its `guard hi > lo`
    /// without ever invoking `transcribeWindow`. Result: a transient
    /// whisper failure permanently silenced live — no further
    /// `transcribeWindow` calls, no respawn retry, just two
    /// backpressure-warning lines per real-time second forever.
    ///
    /// This test drives that exact shape: a transcriber that throws
    /// on every call (so the anchor never advances via a commit), a
    /// short prefix that primes a couple of normal `transcribeWindow`
    /// calls, then a long suffix whose `realTimeElapsed` jumps 70 s
    /// forward (the wedge gap) at the same audio cadence. After the
    /// suffix the streamer must still be calling `transcribeWindow`
    /// — pre-fix that count is 0, post-fix it is several.
    @Test("backpressure clamp does not permanently silence the streamer when realTime runs past available audio")
    func backpressureClampDoesNotSilenceStreamer() {
        let tracker = TrackingWindowTranscriber(
            alwaysThrowing: TranscriptionError.modelLoadFailed("simulated wedge"))
        let runner = StreamingTranscriber(
            transcriber: tracker,
            configuration: .init(
                windowDuration: .seconds(8),
                stepInterval: .seconds(2),
                // VAD disabled so the test isolates the clamp bug from
                // silence-gating. Real audio in the wedge incident was
                // a meeting — peak well over 0.01.
                silencePeakThreshold: 0.0),
            logger: Logger(label: "test"))

        let frame = AudioFrame(
            samples: [Float](repeating: 0.5, count: AudioFormat.samplesPerFrame),
            sequenceIndex: 0)

        // Phase 1 — prime the streamer at real-time for 4 s. Two
        // `transcribeWindow` calls land at the 2 s / 4 s step boundaries.
        let phase1Frames = 200   // 4 s of 20 ms frames
        for i in 0..<phase1Frames {
            let elapsed = Duration.milliseconds(i * 20)
            _ = runner.ingest(frame: frame, realTimeElapsed: elapsed)
        }
        let preWedgeCallCount = tracker.callCount

        // Phase 2 — the wedge gap. realTime jumps forward 70 s while
        // audio continues at the same 20 ms/frame cadence. 500 frames
        // = 10 s of audio at frame rate; with the bug none of them
        // trigger a `transcribeWindow` (runWindow returns early every
        // iteration). With the fix, the anchor cannot pass
        // `recordingSampleCount - windowSamples`, the buffer keeps
        // `windowSamples` of audio in front of it, and runWindow
        // decodes — so transcribeWindow is called every step.
        let wedgeGap = Duration.seconds(70)
        let phase2Frames = 500
        for i in 0..<phase2Frames {
            let elapsed = Duration.milliseconds(phase1Frames * 20)
                + wedgeGap
                + Duration.milliseconds(i * 20)
            _ = runner.ingest(frame: frame, realTimeElapsed: elapsed)
        }
        let postWedgeCallCount = tracker.callCount - preWedgeCallCount

        // Pre-fix: postWedgeCallCount is 0 (the streamer is silent
        // forever once the clamp kicks in).
        // Post-fix: there is at least one transcribeWindow per stepInterval
        // of audio ingested — 500 frames / 100-per-step = 5 attempts.
        // We assert ≥2 to leave slack for off-by-one stepping effects.
        //
        // NOTE (2026-07-30): under the delivered-backlog backpressure
        // semantics the wall-clock gap in this scenario no longer force-
        // advances the anchor *at all* (the backlog stays small). The
        // decoder is called on every step regardless — which is exactly
        // this test's assertion — so it still passes, now via the "no
        // force-advance ⇒ decoder never starved" path rather than the
        // "force-advance but keep windowSamples in the buffer" clamp path.
        #expect(postWedgeCallCount >= 2,
                "streamer must keep calling transcribeWindow after a backpressure-clamp; got \(postWedgeCallCount) calls in phase 2 (phase 1 had \(preWedgeCallCount))")
    }

    // MARK: - Delivered-backlog backpressure (2026-07-30 incident)

    /// Regression for the 2026-07-30 wedge (rec_2026-07-30-133002): during a
    /// system-wide load wedge ~80 s of system audio was dropped *upstream*
    /// (the capture socket layer) and never reached the transcriber. Delivered
    /// audio therefore permanently trailed wall clock by ~78 s — a deficit
    /// that can never close. The old backpressure measured wall-clock lag
    /// (`realSample − windowAnchorSample`), so it fired on *every* window for
    /// the rest of the hour, each firing force-advancing the anchor and
    /// starving LocalAgreement-2 (which needs two consecutive decodes over the
    /// same region to commit). Live output nearly stopped.
    ///
    /// The fix measures the transcriber's own un-decoded backlog
    /// (`recordingSampleCount − windowAnchorSample`) instead. A permanent
    /// upstream deficit leaves the backlog small, so backpressure must NOT
    /// fire and LocalAgreement must keep committing on the audio that did
    /// arrive.
    ///
    /// Shape: audio delivered at a steady step cadence, decoder fast (a
    /// metronome fake that emits committable tokens), `realTimeElapsed`
    /// pinned permanently ~8 windows ahead of delivered audio (the fixed
    /// deficit). Assert: no backpressure warning is ever logged (no force-
    /// advance) and tokens keep committing across many windows.
    @Test("a permanent wall-clock deficit does not force-advance the anchor; commits keep flowing")
    func permanentWallClockDeficitDoesNotStarveCommits() {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }
        let metronome = MetronomeWindowTranscriber(wordEveryMS: 500)
        let runner = StreamingTranscriber(
            transcriber: metronome,
            configuration: .init(
                windowDuration: .seconds(8),
                stepInterval: .seconds(2),
                silencePeakThreshold: 0.0),
            logger: logger)

        let frame = AudioFrame(
            samples: [Float](repeating: 0.5, count: AudioFormat.samplesPerFrame),
            sequenceIndex: 0)

        // Deliver 60 s of audio (3000 frames of 20 ms) while pinning
        // realTimeElapsed 64 s (= 8 × 8 s windows) ahead of delivered audio.
        // Under the OLD wall-clock-lag semantics `lag = realSample − anchor`
        // exceeds 2 windows on every step, so it force-advances every window.
        var committedCount = 0
        let deliveredFrames = 3000
        let deficit = Duration.seconds(64)
        for i in 0..<deliveredFrames {
            let deliveredElapsed = Duration.milliseconds(i * 20)
            let realElapsed = deliveredElapsed + deficit
            let out = runner.ingest(frame: frame, realTimeElapsed: realElapsed)
            committedCount += out.reduce(0) { $0 + $1.text.split(separator: " ").count }
        }

        let warnings = capture.messages.filter {
            $0.contains("backpressure")
        }
        // OLD code: one (or two) backpressure warnings per step → dozens.
        // NEW code: the backlog never exceeds 2 windows → zero.
        #expect(warnings.isEmpty,
                "backpressure must not fire on a permanent wall-clock deficit; saw \(warnings.count): \(warnings.first ?? "")")
        // OLD code: the perpetual force-advance starves LocalAgreement-2, so
        // very few (near-zero) tokens commit. NEW code: commits flow on the
        // audio that arrived.
        #expect(committedCount >= 20,
                "commits must keep flowing on delivered audio; committed \(committedCount) tokens over \(deliveredFrames) frames")
    }

    /// A decoder genuinely slower than real-time must still shed audio: when
    /// the transcriber's own un-decoded backlog exceeds two windows the anchor
    /// force-advances so the backlog after the drain is bounded (≤ 2 windows).
    /// The shed audio is lost to live (coarser commits); the post-pass
    /// recovers it. This is the behavior backpressure is *supposed* to have —
    /// the fix only changes *what triggers it* (delivered backlog, not wall
    /// clock), not that it triggers at all.
    ///
    /// Shape: deliver a single huge burst of audio at once (far more than one
    /// step), with `realTimeElapsed` tracking delivered audio exactly (no
    /// artificial wall-clock deficit — the backlog itself is the trigger).
    /// A never-committing decoder (empty results) means the anchor can only
    /// move via backpressure, so the post-burst backlog directly measures
    /// whether force-advance happened. Assert it fired and bounded the backlog.
    @Test("a genuine decoder backlog beyond two windows force-advances the anchor to shed audio")
    func genuineBacklogForceAdvancesAnchor() {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }
        // Empty results ⇒ the committer never advances the anchor, so any
        // anchor movement is backpressure's doing alone.
        let tracker = TrackingWindowTranscriber()
        let windowDuration = Duration.seconds(8)
        let runner = StreamingTranscriber(
            transcriber: tracker,
            configuration: .init(
                windowDuration: windowDuration,
                stepInterval: .seconds(2),
                silencePeakThreshold: 0.0),
            logger: logger)

        // Deliver 60 s of audio in a single ingest burst. realTimeElapsed
        // tracks delivered audio exactly (60 s), so wall-clock lag is ~0 —
        // the ONLY trigger available is the delivered backlog.
        let burstSeconds = 60
        let framesPerSecond = 1000 / AudioFormat.frameMilliseconds  // 50
        let burst = [Float](
            repeating: 0.5,
            count: burstSeconds * framesPerSecond * AudioFormat.samplesPerFrame)
        let bigFrame = AudioFrame(samples: burst, sequenceIndex: 0)
        _ = runner.ingest(frame: bigFrame, realTimeElapsed: .seconds(burstSeconds))

        // Backpressure must have fired (backlog ≫ 2 windows on the burst).
        let warnings = capture.messages.filter { $0.contains("backpressure") }
        #expect(!warnings.isEmpty,
                "a 60 s burst decoded 8 s at a time must trip backpressure at least once")

        // After the drain the backlog must be bounded to ≤ 2 windows. Parse
        // the final trace line's `backlog=` field (recording-absolute
        // delivered audio still past the anchor).
        let finalBacklog = Self.lastBacklogSeconds(from: capture.messages)
        #expect(finalBacklog != nil, "expected a trace line with a backlog= field")
        if let finalBacklog {
            #expect(finalBacklog <= 16,
                    "backlog after force-advance must be ≤ 2 windows (16 s); was \(finalBacklog)s")
        }
    }

    /// Offline / fast callers pass `realTimeElapsed: nil`, which disables
    /// backpressure entirely — even when a large amount of audio is available
    /// past the anchor, no window is ever force-advanced (shed); every due
    /// window is decoded. Guards that the backlog check stays gated on live
    /// mode.
    ///
    /// The realistic offline shape feeds frames incrementally (that is how the
    /// real callers drive it — one 20 ms frame at a time), so windows keep
    /// coming due as audio accumulates. With backpressure disabled, none of
    /// them are shed regardless of how far the total runs ahead of the anchor.
    @Test("offline callers (realTimeElapsed nil) are never force-advanced")
    func offlineCallersAreNeverForceAdvanced() {
        let capture = CapturingLogHandler()
        let logger = Logger(label: "test") { _ in capture }
        let tracker = TrackingWindowTranscriber()
        let runner = StreamingTranscriber(
            transcriber: tracker,
            configuration: .init(
                windowDuration: .seconds(8),
                stepInterval: .seconds(2),
                silencePeakThreshold: 0.0),
            logger: logger)

        // Feed 60 s of audio one frame at a time, realTimeElapsed nil. The
        // never-committing decoder means the anchor never moves via a commit,
        // so past the first 8 s the total runs ever further ahead of the
        // anchor — the exact condition that trips live-mode backpressure. It
        // must NOT trip here (offline gate). Each 2 s step decodes a window.
        let frame = AudioFrame(
            samples: [Float](repeating: 0.5, count: AudioFormat.samplesPerFrame),
            sequenceIndex: 0)
        let frames = 3000  // 60 s of 20 ms frames
        for _ in 0..<frames {
            _ = runner.ingest(frame: frame, realTimeElapsed: nil)
        }

        let warnings = capture.messages.filter { $0.contains("backpressure") }
        #expect(warnings.isEmpty,
                "offline callers must never trip backpressure; saw \(warnings.count)")
        // Every due window must have been decoded, never shed. 60 s of audio
        // stepped at 2 s = ~30 windows once the first is due.
        #expect(tracker.callCount >= 25,
                "offline audio must decode every due window; got \(tracker.callCount)")
    }

    /// Parse the `backlog=<n>s` field from the most recent
    /// `live trace transcriber` line, or `nil` if none carry it.
    private static func lastBacklogSeconds(from messages: [String]) -> Int? {
        for message in messages.reversed() {
            guard let range = message.range(of: "backlog=") else { continue }
            let after = message[range.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }
}

/// A `WindowTranscribing` that throws a configured error on every call.
private final class ThrowingWindowTranscriber: WindowTranscribing, @unchecked Sendable {
    let error: Error
    init(error: Error) { self.error = error }
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: TranscriptionOptions
    ) throws -> TranscriptionResult {
        throw error
    }
}

/// A `WindowTranscribing` that counts every call. If
/// `alwaysThrowing` is set, every call rethrows it; otherwise the
/// transcriber returns an empty result.
private final class TrackingWindowTranscriber: WindowTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let alwaysThrowing: Error?

    var callCount: Int { lock.withLock { _callCount } }

    init(alwaysThrowing error: Error? = nil) { self.alwaysThrowing = error }

    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: TranscriptionOptions
    ) throws -> TranscriptionResult {
        lock.withLock { _callCount += 1 }
        if let alwaysThrowing { throw alwaysThrowing }
        return TranscriptionResult(segments: [], language: "en")
    }
}

/// A deterministic "metronome" `WindowTranscribing`: for a window covering
/// recording-absolute `[windowStart, windowStart + windowLen]` it emits one
/// numbered word per `wordEveryMS` of absolute audio time (word text = the
/// bucket index, e.g. `w42`). Because two overlapping windows produce
/// *identical* words for the same absolute region, LocalAgreement-2 commits
/// their overlap — a faithful, anchor-position-independent stand-in for a real
/// streaming decoder, with no audio content dependence and no wall clock.
private final class MetronomeWindowTranscriber: WindowTranscribing, @unchecked Sendable {
    private let wordEveryMS: Int
    init(wordEveryMS: Int) { self.wordEveryMS = wordEveryMS }

    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: TranscriptionOptions
    ) throws -> TranscriptionResult {
        let startMS = durationMS(windowStart)
        let windowLenMS = samples.count * 1000 / AudioFormat.sampleRate
        let endMS = startMS + windowLenMS
        // Buckets are on an absolute grid so overlapping windows share words.
        let firstBucket = (startMS + wordEveryMS - 1) / wordEveryMS
        let lastBucket = endMS / wordEveryMS
        guard lastBucket >= firstBucket else {
            return TranscriptionResult(segments: [], language: "en")
        }
        var segments: [TranscriptSegment] = []
        for bucket in firstBucket...lastBucket {
            let wStart = Duration.milliseconds(bucket * wordEveryMS)
            let wEnd = wStart + .milliseconds(wordEveryMS)
            segments.append(TranscriptSegment(
                start: wStart, end: wEnd, text: "w\(bucket)"))
        }
        return TranscriptionResult(segments: segments, language: "en")
    }

    private func durationMS(_ d: Duration) -> Int {
        Int(d.components.seconds) * 1000
            + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}
