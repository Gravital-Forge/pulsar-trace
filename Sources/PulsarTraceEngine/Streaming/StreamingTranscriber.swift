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
/// realtime mode) and emits **committed** utterances with ≤ 5 s lag behind real
/// time.
///
/// ## Anchored-window whisper + LocalAgreement-2
///
/// whisper has no true streaming mode; it transcribes a buffer. The streaming
/// approach here (the `whisper_streaming` design):
///
///  1. **Accumulate** incoming 20 ms frames into a rolling sample buffer.
///  2. The decode window is **anchored at the last committed audio position**
///     — *not* a free-sliding window. Every `stepInterval` of new audio, run
///     whisper on `[committedAudioEnd, committedAudioEnd + windowDuration]`.
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
/// whisper on a window must finish before the next window is due, or the
/// sample buffer grows unbounded. The transcriber tracks how far decoding lags
/// real audio; if a window decode overruns it **skips** windows to catch up
/// (coarser commits, but bounded memory and bounded lag) and logs the overrun.
/// It never blocks the source or crashes.
///
/// Not `Sendable` by construction — it owns a non-`Sendable` `WhisperTranscriber`.
/// Drive it from one task.
public final class StreamingTranscriber {

    /// Tunables for the sliding-window streaming loop.
    public struct Configuration: Sendable {
        /// Length of the audio window each whisper run sees. Long enough for
        /// whisper to have useful context, short enough to decode fast.
        public var windowDuration: Duration
        /// How much *new* audio accumulates before the next window is decoded.
        /// `windowDuration − stepInterval` is the overlap that catches
        /// chunk-boundary words.
        public var stepInterval: Duration
        /// Per-window VAD gate: a window whose peak |sample| is below this is
        /// treated as silence and skipped (no whisper run, no hallucination).
        public var silencePeakThreshold: Float
        /// Silence gap between two committed tokens above which they are split
        /// into separate utterances.
        public var utteranceGap: Duration
        /// whisper decode options for each window.
        public var whisperOptions: WhisperTranscriber.Options

        public init(
            windowDuration: Duration = .seconds(8),
            stepInterval: Duration = .seconds(2),
            silencePeakThreshold: Float = 0.01,
            utteranceGap: Duration = .milliseconds(800),
            whisperOptions: WhisperTranscriber.Options = .init()
        ) {
            self.windowDuration = windowDuration
            self.stepInterval = stepInterval
            self.silencePeakThreshold = silencePeakThreshold
            self.utteranceGap = utteranceGap
            self.whisperOptions = whisperOptions
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
    /// The language whisper detected on the most recent decoded window — `nil`
    /// until the first non-silent window decodes. Surfaced so the live pass's
    /// `Output.language` reflects what whisper actually heard, not a hardcoded
    /// guess. A window whose detected language is `"unknown"` does not replace
    /// a previously-detected real language.
    private var lastDetectedLanguage: String?

    /// The language of the most recently decoded window (ISO-639-1, e.g.
    /// `en`), or `nil` if no window has been decoded yet.
    public var detectedLanguage: String? { lastDetectedLanguage }

    public init(
        transcriber: any WindowTranscribing,
        configuration: Configuration = .init(),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.transcriber = transcriber
        self.configuration = configuration
        self.logger = logger
    }

    private var stepSamples: Int {
        durationToSamples(configuration.stepInterval)
    }
    private var windowSamples: Int {
        durationToSamples(configuration.windowDuration)
    }

    /// Ingest one 20 ms frame. When enough new audio has accumulated for the
    /// next window, runs whisper and returns any utterances newly committed by
    /// LocalAgreement-2. Most calls return `[]`.
    ///
    /// - Parameter realTimeElapsed: wall-clock elapsed since the stream began,
    ///   used only for the backpressure check / lag logging. Pass `nil` to
    ///   disable backpressure handling (offline/fast callers).
    /// - Parameter abort: a watchdog cancellation token threaded into each
    ///   window decode so a hung/runaway window can be interrupted (Phase 2).
    ///   `nil` disables it.
    public func ingest(
        frame: AudioFrame,
        realTimeElapsed: Duration? = nil,
        abort: AbortToken? = nil
    ) -> [CommittedUtterance] {
        samples.append(contentsOf: frame.samples)
        return drainWindows(realTimeElapsed: realTimeElapsed, abort: abort)
    }

    /// End-of-stream: decode any remaining tail audio and flush the committer
    /// (the final hypothesis has no successor to agree with, so its tail is
    /// committed unconditionally — see `LiveAgreementCommitter.flush`).
    public func finish() -> [CommittedUtterance] {
        // The end-of-stream flush is bounded by the worker-drain teardown, not
        // the per-decode watchdog, so it passes no abort token.
        var out = drainWindows(realTimeElapsed: nil, abort: nil)
        // One last anchored window covering everything from the commit point
        // to end-of-stream, so no tail audio is missed.
        if recordingSampleCount > windowAnchorSample {
            runWindow(abort: nil)
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
        realTimeElapsed: Duration?,
        abort: AbortToken?
    ) -> [CommittedUtterance] {
        // A window is due once `stepSamples` of new audio have arrived since
        // the last decode AND there is at least one step of audio past the
        // anchor to transcribe.
        while recordingSampleCount - lastDecodeEndSample >= stepSamples
            && recordingSampleCount - windowAnchorSample >= stepSamples {

            // Backpressure: if real time has run far past
            // the anchor — whisper cannot keep up — skip the anchor forward so
            // the buffer and the lag stay bounded. The skipped audio is lost
            // to the live pass (coarser commits); the post-pass recovers it.
            if let realTimeElapsed {
                let realSample = durationToSamples(realTimeElapsed)
                let lagSamples = realSample - windowAnchorSample
                if lagSamples > 2 * windowSamples {
                    logger.warning(
                        "streaming transcription backpressure: decode lag exceeds two windows; advancing anchor to catch up")
                    advanceAnchor(to: realSample - windowSamples)
                }
            }

            runWindow(abort: abort)
            lastDecodeEndSample = recordingSampleCount
        }
        return regroupNewlyCommitted()
    }

    /// Run whisper on the anchored window `[windowAnchorSample, +windowDuration]`
    /// (clamped to available audio), feed the hypothesis to the committer, and
    /// advance the anchor + trim the buffer to whatever was committed.
    private func runWindow(abort: AbortToken?) {
        let loAbs = windowAnchorSample
        let hiAbs = min(recordingSampleCount, loAbs + windowSamples)
        let lo = loAbs - bufferBaseSample
        let hi = hiAbs - bufferBaseSample
        guard hi > lo, lo >= 0, hi <= samples.count else { return }
        let window = Array(samples[lo..<hi])

        // VAD gate: skip an essentially-silent window. No whisper run means no
        // silence hallucination, and the committer's previous tail is left
        // intact so a real word straddling the silence still commits later.
        let peak = window.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
        guard peak >= configuration.silencePeakThreshold else { return }

        let windowStart = samplesToDuration(loAbs)
        let result: TranscriptionResult
        do {
            result = try transcriber.transcribeWindow(
                window,
                windowStart: windowStart,
                options: configuration.whisperOptions,
                abort: abort)
        } catch {
            logger.error("streaming window decode failed; skipping window")
            return
        }
        // Record what whisper detected so the live pass's Output.language is
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
