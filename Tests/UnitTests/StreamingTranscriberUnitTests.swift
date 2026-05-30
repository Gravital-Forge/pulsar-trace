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
            error: WhisperTranscribeError.modelLoadFailed(
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
            alwaysThrowing: WhisperTranscribeError.modelLoadFailed("simulated wedge"))
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
        #expect(postWedgeCallCount >= 2,
                "streamer must keep calling transcribeWindow after a backpressure-clamp; got \(postWedgeCallCount) calls in phase 2 (phase 1 had \(preWedgeCallCount))")
    }
}

/// A `WindowTranscribing` that throws a configured error on every call.
private final class ThrowingWindowTranscriber: WindowTranscribing, @unchecked Sendable {
    let error: Error
    init(error: Error) { self.error = error }
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperOptions,
        abort: AbortToken?
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
        options: WhisperOptions,
        abort: AbortToken?
    ) throws -> TranscriptionResult {
        lock.withLock { _callCount += 1 }
        if let alwaysThrowing { throw alwaysThrowing }
        return TranscriptionResult(segments: [], language: "en")
    }
}

/// Lock-protected log sink — same shape as the `RemoteWindowTranscriber`
/// tests' helper. The tests assert on `messages` after the call returns.
private final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _m: [String] = []
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey k: String) -> Logger.Metadata.Value? {
        get { metadata[k] } set { metadata[k] = newValue }
    }
    var messages: [String] { lock.withLock { _m } }
    func log(level: Logger.Level, message: Logger.Message,
             metadata: Logger.Metadata?, source: String,
             file: String, function: String, line: UInt) {
        lock.withLock { _m.append("\(message)") }
    }
}
