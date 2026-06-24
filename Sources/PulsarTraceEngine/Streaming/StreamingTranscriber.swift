import Foundation
import Logging

/// A committed streaming utterance — text plus the recording-absolute span the
/// LocalAgreement-2 committer settled on. The streaming analogue of
/// `TranscriptSegment`; it is only ever produced once *stable* (R10).
public struct CommittedUtterance: Sendable, Equatable {
    /// Recording-absolute offset of the utterance's first word.
    public let start: Duration
    /// Recording-absolute offset of the utterance's last word.
    public let end: Duration
    /// The committed text.
    public let text: String

    public init(start: Duration, end: Duration, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Streaming transcription for the live pass (R10).
///
/// Consumes any `AudioFrameSource` at whatever pace the source delivers frames
/// (real-time for a device / `ffmpeg -re` pipe / `FixturePlaybackSource`
/// realtime mode) and emits **committed** utterances within ~one `stepInterval`
/// of real time, plus per-window decode latency.
///
/// ## Anchored-window decode + LocalAgreement-2
///
/// The transcriber has no true streaming mode; it decodes a buffer. The
/// streaming approach here (the `whisper_streaming` design):
///
///  1. **Accumulate** incoming 20 ms frames into a rolling sample buffer.
///  2. The decode window is **anchored at the last committed audio position**
///     — *not* a free-sliding window. Every `stepInterval` of new audio, run
///     the transcriber on `[committedAudioEnd, committedAudioEnd + windowDuration]`.
///     Because consecutive windows share the same start, two consecutive
///     hypotheses share a *prefix*, which is exactly what LocalAgreement-2
///     compares. (A freely-sliding window would share only a middle and never
///     commit.) A word split by the window's far edge is seen whole next time.
///  3. Feed each window's hypothesis to a `LiveAgreementCommitter`: only the
///     longest prefix that **two consecutive windows agree on** is committed
///     (LocalAgreement-2). Unstable tail words are held back, never emitted —
///     so `live.md` only grows and is never rewritten (R36).
///  4. When the window grows past `windowDuration` past the commit point, the
///     buffer is trimmed at the commit point so memory stays bounded.
///  5. Group newly-committed tokens back into utterances (split on a silence
///     gap) and hand them to the caller.
///
/// VAD gating: a window that is essentially silent is skipped entirely, and
/// `BlankTokenFilter` drops `[BLANK_AUDIO]` / silence-hallucination segments —
/// so a quiet meeting does not accrete "thanks for watching" lines.
///
/// ## Backpressure
///
/// The decode of a window must finish before the next window is due, or the
/// sample buffer grows unbounded. The transcriber tracks how far decoding lags
/// real audio; if a window decode overruns it **skips** windows to catch up
/// (coarser commits, but bounded memory and bounded lag) and logs the overrun.
/// It never blocks the source or crashes.
///
/// Not `Sendable` by construction — it owns a non-`Sendable`
/// `WindowTranscribing` conformer. Drive it from one task.
public final class StreamingTranscriber {

    /// Tunables for the sliding-window streaming loop.
    public struct Configuration: Sendable {
        /// Length of the audio window each decode sees. Long enough for the
        /// transcriber to have useful context, short enough to decode fast.
        public var windowDuration: Duration
        /// How much *new* audio accumulates before the next window is decoded.
        /// `windowDuration − stepInterval` is the overlap that catches
        /// chunk-boundary words.
        public var stepInterval: Duration
        /// Per-window VAD gate: a window whose peak |sample| is below this is
        /// treated as silence and skipped (no decode, no hallucination).
        public var silencePeakThreshold: Float
        /// Silence gap between two committed tokens above which they are split
        /// into separate utterances.
        public var utteranceGap: Duration
        /// Decode options for each window.
        public var options: TranscriptionOptions

        public init(
            windowDuration: Duration = .seconds(10),
            stepInterval: Duration = .seconds(4),
            silencePeakThreshold: Float = 0.01,
            utteranceGap: Duration = .milliseconds(800),
            options: TranscriptionOptions = .init()
        ) {
            self.windowDuration = windowDuration
            self.stepInterval = stepInterval
            self.silencePeakThreshold = silencePeakThreshold
            self.utteranceGap = utteranceGap
            self.options = options
        }
    }

    private let transcriber: any WindowTranscribing
    private let configuration: Configuration
    private let logger: Logger

    /// The rolling sample buffer (mono 16 kHz Float32). Trimmed at the front
    /// once audio is committed, so it stays bounded over a long recording.
    private var samples: [Float] = []
    /// Recording-absolute sample index of `samples[0]` — the buffer is trimmed
    /// at the front, so an index into `samples` is `bufferBaseSample` smaller
    /// than the recording-absolute index.
    private var bufferBaseSample = 0
    /// Recording-absolute sample index the decode window is anchored at — the
    /// end of the last committed audio. Windows always start here so two
    /// consecutive hypotheses share a prefix (LocalAgreement-2 needs this).
    private var windowAnchorSample = 0
    /// Recording-absolute sample count decoded so far, to pace the step.
    private var lastDecodeEndSample = 0
    /// LocalAgreement-2 committer accumulating stable tokens.
    private var committer = LiveAgreementCommitter()
    /// Committer tokens already grouped into delivered utterances, so a flush
    /// or re-group never re-emits one.
    private var deliveredTokenCount = 0
    /// The language the decoder detected on the most recent decoded window —
    /// `nil` until the first non-silent window decodes. Surfaced so the live
    /// pass's `Output.language` reflects what the decoder actually heard, not a
    /// hardcoded guess. A window whose detected language is `"unknown"` does not
    /// replace a previously-detected real language.
    private var lastDetectedLanguage: String?

    /// Diagnostic ("system"/"mic"): names this transcriber's stream in the
    /// per-pass `live trace transcriber` log line.
    private let streamLabel: String
    /// Diagnostic: wall-clock ms of the most recent window decode (0 when the
    /// window was VAD-skipped or empty).
    private var lastDecodeMS = 0.0
    /// Diagnostic: whether the most recent window was skipped by the VAD gate.
    private var lastVADSkipped = false

    /// The language of the most recently decoded window (ISO-639-1, e.g.
    /// `en`), or `nil` if no window has been decoded yet.
    public var detectedLanguage: String? { lastDetectedLanguage }

    public init(
        transcriber: any WindowTranscribing,
        configuration: Configuration = .init(),
        logger: Logger = Logger(label: LogSubsystem.engine),
        streamLabel: String = "?"
    ) {
        self.transcriber = transcriber
        self.configuration = configuration
        self.logger = logger
        self.streamLabel = streamLabel
    }

    private var stepSamples: Int {
        durationToSamples(configuration.stepInterval)
    }
    private var windowSamples: Int {
        durationToSamples(configuration.windowDuration)
    }

    /// Ingest one 20 ms frame. When enough new audio has accumulated for the
    /// next window, runs the transcriber and returns any utterances newly
    /// committed by LocalAgreement-2. Most calls return `[]`.
    ///
    /// - Parameter realTimeElapsed: wall-clock elapsed since the stream began,
    ///   used only for the backpressure check / lag logging. Pass `nil` to
    ///   disable backpressure handling (offline/fast callers).
    public func ingest(
        frame: AudioFrame,
        realTimeElapsed: Duration? = nil
    ) -> [CommittedUtterance] {
        samples.append(contentsOf: frame.samples)
        return drainWindows(realTimeElapsed: realTimeElapsed)
    }

    /// End-of-stream: decode any remaining tail audio and flush the committer
    /// (the final hypothesis has no successor to agree with, so its tail is
    /// committed unconditionally — see `LiveAgreementCommitter.flush`).
    public func finish() -> [CommittedUtterance] {
        var out = drainWindows(realTimeElapsed: nil)
        // One last anchored window covering everything from the commit point
        // to end-of-stream, so no tail audio is missed.
        if recordingSampleCount > windowAnchorSample {
            runWindow()
        }
        _ = committer.flush()
        out.append(contentsOf: regroupNewlyCommitted())
        return out
    }

    /// The full committed transcript so far (every token committed, grouped).
    public func committedTranscript() -> [CommittedUtterance] {
        Self.groupTokens(
            committer.committed, gap: configuration.utteranceGap)
    }

    // MARK: - Window scheduling

    /// Recording-absolute count of samples seen so far.
    private var recordingSampleCount: Int { bufferBaseSample + samples.count }

    /// Decode every window that is now "due" given the accumulated audio.
    private func drainWindows(
        realTimeElapsed: Duration?
    ) -> [CommittedUtterance] {
        // A window is due once `stepSamples` of new audio have arrived since
        // the last decode AND there is at least one step of audio past the
        // anchor to transcribe.
        while recordingSampleCount - lastDecodeEndSample >= stepSamples
            && recordingSampleCount - windowAnchorSample >= stepSamples {

            // Backpressure: if real time has run far past
            // the anchor — the decoder cannot keep up — skip the anchor forward
            // so the buffer and the lag stay bounded. The skipped audio is lost
            // to the live pass (coarser commits); the post-pass recovers it.
            //
            // Cap the backpressure target at `recordingSampleCount −
            // windowSamples` so the anchor never advances past where
            // `windowSamples` of audio remains. Without this cap a wedge
            // big enough to make `realSample − windowSamples` exceed
            // `recordingSampleCount` lets `advanceAnchor` clamp to
            // `recordingSampleCount`, which empties the sample buffer;
            // `runWindow` then hits its `guard hi > lo` and returns
            // without calling `transcribeWindow`. The streamer keeps
            // logging backpressure but never asks the decoder to decode
            // anything, so a transient decode failure permanently
            // silences live (2026-05-28 incident). With the cap the
            // next `runWindow` always has the most recent `windowSamples`
            // of audio to decode, so the next attempt re-enters the decoder
            // and can recover the moment it catches up.
            if let realTimeElapsed {
                let realSample = durationToSamples(realTimeElapsed)
                let lagSamples = realSample - windowAnchorSample
                if lagSamples > 2 * windowSamples {
                    logger.warning(
                        "streaming transcription backpressure: decode lag exceeds two windows; advancing anchor to catch up")
                    let safeTarget = min(
                        realSample - windowSamples,
                        recordingSampleCount - windowSamples)
                    advanceAnchor(to: safeTarget)
                }
            }

            runWindow()
            lastDecodeEndSample = recordingSampleCount

            // Per-pass diagnostic trace (numbers only — Hard Invariant #7).
            let _sr = AudioFormat.sampleRate
            let _realSample = realTimeElapsed.map { durationToSamples($0) }
                ?? recordingSampleCount
            let _lag = Double(_realSample - windowAnchorSample) / Double(_sr)
            logger.notice("""
                live trace transcriber[\(streamLabel)]: \
                anchor=\(windowAnchorSample / _sr)s total=\(recordingSampleCount / _sr)s \
                lag=\(String(format: "%.1f", _lag))s buf=\(samples.count / _sr)s \
                decode=\(Int(lastDecodeMS))ms vad=\(lastVADSkipped) \
                committedTokens=\(committer.committed.count)
                """)
        }
        return regroupNewlyCommitted()
    }

    /// Run the transcriber on the anchored window
    /// `[windowAnchorSample, +windowDuration]` (clamped to available audio),
    /// feed the hypothesis to the committer, and advance the anchor + trim the
    /// buffer to whatever was committed.
    private func runWindow() {
        lastDecodeMS = 0
        lastVADSkipped = false
        let loAbs = windowAnchorSample
        let hiAbs = min(recordingSampleCount, loAbs + windowSamples)
        let lo = loAbs - bufferBaseSample
        let hi = hiAbs - bufferBaseSample
        guard hi > lo, lo >= 0, hi <= samples.count else { return }
        let window = Array(samples[lo..<hi])

        // VAD gate: skip an essentially-silent window. No decode means no
        // silence hallucination, and the committer's previous tail is left
        // intact so a real word straddling the silence still commits later.
        let peak = window.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
        guard peak >= configuration.silencePeakThreshold else {
            lastVADSkipped = true
            return
        }

        let windowStart = samplesToDuration(loAbs)
        let result: TranscriptionResult
        let _decodeT0 = ContinuousClock.now
        do {
            result = try transcriber.transcribeWindow(
                window,
                windowStart: windowStart,
                options: configuration.options)
        } catch {
            // Interpolate the underlying error so log-greppers see the
            // real cause (model load failure, decode deadline, etc.).
            // Before 2026-05-27 this catch dropped the payload and any
            // diagnostic chain that ran into it dead-ended at "skipping
            // window" with no further context.
            logger.error("streaming window decode failed; skipping window: \(error)")
            return
        }
        lastDecodeMS = (ContinuousClock.now - _decodeT0).seconds * 1000
        // Record what the decoder detected so the live pass's Output.language is
        // accurate. `"unknown"` never overwrites a real language already seen.
        if result.language != "unknown" {
            lastDetectedLanguage = result.language
        }
        if result.language != "en" && result.language != "unknown" {
            let lang = result.language
            logger.warning(
                "streaming transcription: non-English audio detected (\(lang)); live transcript may be unreliable")
        }

        // Flatten the window's non-blank segments to committer tokens.
        var hypothesis: [LiveAgreementCommitter.Token] = []
        for seg in result.segments where !BlankTokenFilter.isBlank(seg.text) {
            hypothesis.append(contentsOf: LiveAgreementCommitter.tokens(
                from: seg.text, start: seg.start, end: seg.end))
        }
        let newlyCommitted = committer.ingest(hypothesis)

        // Advance the anchor to the end of the newly-committed audio so the
        // next window starts there — keeping consecutive hypotheses
        // prefix-aligned — and trim the buffer to bound memory.
        if let lastCommitted = newlyCommitted.last {
            let committedEnd = durationToSamples(lastCommitted.end)
            advanceAnchor(to: committedEnd)
        }
    }

    /// Move the decode anchor forward to recording-absolute sample `target`
    /// (clamped so it never moves backward or past the buffered audio) and
    /// trim the now-superseded front of the sample buffer.
    private func advanceAnchor(to target: Int) {
        let clamped = min(max(target, windowAnchorSample), recordingSampleCount)
        windowAnchorSample = clamped
        // Trim everything before the anchor — that audio is committed and will
        // never be decoded again. Keep `bufferBaseSample` in sync.
        let trim = windowAnchorSample - bufferBaseSample
        if trim > 0 && trim <= samples.count {
            samples.removeFirst(trim)
            bufferBaseSample += trim
        }
    }

    /// Group any committed tokens not yet delivered into utterances and mark
    /// them delivered.
    private func regroupNewlyCommitted() -> [CommittedUtterance] {
        guard committer.committed.count > deliveredTokenCount else { return [] }
        let fresh = Array(committer.committed.suffix(
            from: deliveredTokenCount))
        deliveredTokenCount = committer.committed.count
        return Self.groupTokens(fresh, gap: configuration.utteranceGap)
    }

    // MARK: - Pure helpers

    /// Group a run of committer tokens into utterances, splitting on a silence
    /// gap larger than `gap`.
    static func groupTokens(
        _ tokens: [LiveAgreementCommitter.Token],
        gap: Duration
    ) -> [CommittedUtterance] {
        guard !tokens.isEmpty else { return [] }
        var utterances: [CommittedUtterance] = []
        var groupWords: [String] = []
        var groupStart = tokens[0].start
        var groupEnd = tokens[0].end

        func flushGroup() {
            guard !groupWords.isEmpty else { return }
            utterances.append(CommittedUtterance(
                start: groupStart,
                end: groupEnd,
                text: groupWords.joined(separator: " ")))
        }

        for (i, token) in tokens.enumerated() {
            if i > 0 && token.start - groupEnd > gap {
                flushGroup()
                groupWords = []
                groupStart = token.start
            }
            groupWords.append(token.text)
            groupEnd = token.end
        }
        flushGroup()
        return utterances
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
