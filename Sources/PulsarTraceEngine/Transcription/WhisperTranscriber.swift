import Foundation
import CWhisper
import Logging

/// A transcribed utterance: text plus its time span relative to recording start.
public struct TranscriptSegment: Sendable, Equatable {
    /// Offset from recording start to the segment's first sample.
    public let start: Duration
    /// Offset from recording start to the segment's last sample.
    public let end: Duration
    /// The recognized text, trimmed; never empty (blank segments are dropped).
    public let text: String

    public init(start: Duration, end: Duration, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Result of an offline transcription run.
public struct TranscriptionResult: Sendable, Equatable {
    /// The non-blank utterances, in time order.
    public let segments: [TranscriptSegment]
    /// The language whisper detected/used (ISO-639-1, e.g. `en`).
    public let language: String

    public init(segments: [TranscriptSegment], language: String) {
        self.segments = segments
        self.language = language
    }
}

/// A contiguous span of detected voice activity in a recording, in
/// recording-relative time.
///
/// Produced by `WhisperTranscriber.detectSpeechRegions(in:vadModelURL:…)` and
/// consumed by `transcribe(_:regions:options:)`, which decodes each region
/// independently so the offline transcript breaks at conversational turn
/// pauses instead of emitting one long segment that the time-order merge would
/// float ahead of an interleaved speaker.
public struct SpeechRegion: Sendable, Equatable {
    /// Offset from recording start to the region's first sample.
    public let start: Duration
    /// Offset from recording start to the region's last sample.
    public let end: Duration

    public init(start: Duration, end: Duration) {
        self.start = start
        self.end = end
    }
}

/// Offline transcription via whisper.cpp's C API (R9).
///
/// One `WhisperTranscriber` owns exactly one `whisper_context`, loaded once at
/// init and kept resident for the object's lifetime — no per-call model reload,
/// no `whisper-cli` subprocess. The model file is loaded with Metal
/// acceleration enabled (the library is built `-DGGML_METAL=ON`).
///
/// Epic 2 is offline-only: `transcribe(_:)` takes the *whole* recording as one
/// contiguous Float32 buffer and makes a single `whisper_full` call. With no
/// chunking there are no chunk-boundary artifacts, which satisfies R11 for the
/// offline path. Streaming/overlap-windowing is Epic 6.
///
/// Decoding (`transcribe(_:)`): greedy sampling with a small temperature and
/// whisper's temperature fallback enabled — a window that fails whisper's
/// quality checks is re-decoded hotter instead of its garbage tokens
/// poisoning every later window in the same `whisper_full` call. whisper.cpp
/// seeds its sampler RNG with a fixed per-call constant (`std::mt19937(0)`),
/// so output is still byte-reproducible run-to-run on a given build. An
/// optional Silero VAD model drops non-speech regions before decoding so a
/// long digital-silence stretch can't drive the decoder into that degenerate
/// state in the first place. See `Options`.
///
/// Not `Sendable`: `whisper_context` is not thread-safe. Use one transcriber
/// per source from a single task.
///
/// Metal serialization: whisper.cpp's Metal backend keeps a per-device
/// residency set that asserts (`GGML_ASSERT(rsets->data count == 0)`) if two
/// `whisper_context`s are constructed/freed concurrently in one process. Epic 2
/// is one source = one transcriber, but the engine is a long-lived process and
/// nothing stops a future caller (Epic 4 re-refine, tests) from holding two at
/// once. A process-wide lock makes context create/free and each `whisper_full`
/// call mutually exclusive — correctness over a theoretical parallel speedup
/// that the offline path doesn't need anyway. See project-docs/DECISIONS.md D8.
///
/// GPU backend: `useGPU` defaults to `true` (production — Metal). The test/CI
/// path passes `useGPU: false` to use whisper's CPU backend, which avoids the
/// ggml-metal device entirely and so cannot trip the upstream
/// `ggml_metal_device_free` residency-set assertion that fires at process exit
/// when many `whisper_context`s are created/freed in one process. See
/// project-docs/DECISIONS.md D15.
public final class WhisperTranscriber {

    /// Guards `whisper_context` lifecycle and `whisper_full` across the
    /// process so the Metal backend never sees concurrent contexts.
    private static let metalLock = NSLock()

    public enum TranscribeError: Error, CustomStringConvertible, Equatable {
        case modelNotFound(String)
        case modelLoadFailed(String)
        case transcriptionFailed(Int)
        case emptyAudio

        public var description: String {
            switch self {
            case .modelNotFound(let p): return "whisper model not found: \(p)"
            case .modelLoadFailed(let p): return "whisper model failed to load: \(p)"
            case .transcriptionFailed(let c): return "whisper_full failed with code \(c)"
            case .emptyAudio: return "no audio samples to transcribe"
            }
        }
    }

    /// Tunables for a transcription run. The defaults target the offline
    /// refine pass; production may raise `threadCount`.
    public struct Options: Sendable {
        /// `nil` → auto-detect (whisper picks the language). A two-letter code
        /// forces that language. The default multilingual `base`/`large-v3`
        /// models support auto-detect.
        public var language: String?
        /// Decoder threads. 1 keeps output deterministic and is plenty for the
        /// offline path on a fixture; bump for large recordings.
        public var threadCount: Int
        /// whisper's no-speech threshold — segments above this probability of
        /// being non-speech are dropped by whisper before they reach us. Guards
        /// against silence hallucinations ("thanks for watching").
        public var noSpeechThreshold: Float
        /// Decoder temperature for the *first* decode pass. whisper.cpp samples
        /// the token distribution when this is > 0; its sampler RNG is seeded
        /// with a fixed constant per `whisper_full` call, so a non-zero value
        /// is still byte-reproducible run-to-run on a given build. `0` is pure
        /// argmax. Read by `transcribe(_:)` only — `transcribeWindow` keeps
        /// argmax for committer stability.
        public var temperature: Float
        /// Temperature step for whisper's fallback re-decode. When a segment
        /// fails whisper's quality checks (compression-ratio / avg-logprob /
        /// no-speech), whisper retries it at `temperature + step`, then
        /// `+ 2·step`, … up to 1.0. This is whisper's primary escape from a
        /// degenerate greedy-decode loop: at `0` a failed window has no
        /// fallback and its garbage tokens poison every later window in the
        /// same call. Read by `transcribe(_:)` only.
        public var temperatureFallbackStep: Float
        /// Path to a ggml Silero VAD model. When set, `transcribe(_:)` enables
        /// whisper.cpp's built-in voice-activity detection: non-speech regions
        /// are dropped before decoding, so a long digital-silence stretch in a
        /// recording can't drive the decoder into a degenerate state. `nil`
        /// disables VAD (whole-buffer decode). Ignored by `transcribeWindow`,
        /// which the streaming pipeline already VAD-gates upstream.
        public var vadModelURL: URL?

        public init(
            language: String? = nil,
            threadCount: Int = 1,
            noSpeechThreshold: Float = 0.6,
            temperature: Float = 0.2,
            temperatureFallbackStep: Float = 0.2,
            vadModelURL: URL? = nil
        ) {
            self.language = language
            self.threadCount = threadCount
            self.noSpeechThreshold = noSpeechThreshold
            self.temperature = temperature
            self.temperatureFallbackStep = temperatureFallbackStep
            self.vadModelURL = vadModelURL
        }
    }

    private let ctx: OpaquePointer
    private let modelURL: URL
    private let logger: Logger
    /// True when the model file name marks an English-only model (`*.en`).
    private let isEnglishOnlyModel: Bool

    /// Default GPU setting, resolved from the environment.
    ///
    /// `PULSARTRACE_WHISPER_CPU` set to `1`/`true`/`yes` forces whisper's CPU
    /// backend process-wide. This is the escape hatch for hosts where the Metal
    /// GPU is unreachable — notably a command sandbox that denies IOKit GPU
    /// access, where the Metal backend crashes during buffer allocation. The
    /// production default is GPU (Metal).
    public static var gpuEnabledByDefault: Bool {
        switch ProcessInfo.processInfo.environment["PULSARTRACE_WHISPER_CPU"]?
            .lowercased()
        {
        case "1", "true", "yes": return false
        default: return true
        }
    }

    /// Load a ggml whisper model file and keep it resident.
    ///
    /// - Parameters:
    ///   - modelURL: a `ggml-*.bin` file (`base`, `large-v3`, …).
    ///   - useGPU: loads the model on the Metal backend (production) when
    ///     `true`, or whisper's CPU backend when `false`. Defaults to
    ///     `gpuEnabledByDefault` — GPU unless `PULSARTRACE_WHISPER_CPU` is set.
    ///     The test/CI suite passes `false` explicitly so it never touches the
    ///     ggml-metal device and so cannot trip the upstream exit-time
    ///     residency-set assertion (project-docs/DECISIONS.md D15).
    public init(
        modelURL: URL,
        useGPU: Bool = WhisperTranscriber.gpuEnabledByDefault,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) throws {
        self.modelURL = modelURL
        self.logger = logger
        self.isEnglishOnlyModel =
            modelURL.deletingPathExtension().lastPathComponent.hasSuffix(".en")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw TranscribeError.modelNotFound(modelURL.path)
        }

        var cparams = whisper_context_default_params()
        // Metal (production) — the library is built -DGGML_METAL=ON — or the
        // CPU backend for tests/CI (project-docs/DECISIONS.md D15).
        cparams.use_gpu = useGPU

        Self.metalLock.lock()
        let loaded = modelURL.path.withCString {
            whisper_init_from_file_with_params($0, cparams)
        }
        Self.metalLock.unlock()

        guard let loaded else {
            throw TranscribeError.modelLoadFailed(modelURL.path)
        }
        self.ctx = loaded
        logger.notice(
            "whisper model loaded; multilingual=\(!isEnglishOnlyModel), gpu=\(useGPU)")
    }

    deinit {
        Self.metalLock.lock()
        whisper_free(ctx)
        Self.metalLock.unlock()
    }

    /// Transcribe a whole recording given as one contiguous Float32 PCM buffer.
    ///
    /// `samples` must be 16 kHz mono in [-1, 1] — the engine's canonical format
    /// (`AudioFormat`). This is a single `whisper_full` call (offline path);
    /// `transcribe(_:regions:options:)` is the VAD-segmented variant the refine
    /// pass prefers.
    ///
    /// - Important: this is a blocking, CPU/GPU-bound call that runs for seconds
    ///   (longer for `large-v3` or long recordings) and holds a process-wide
    ///   lock. It must never be called from the main actor — dispatch it to a
    ///   background task/queue.
    public func transcribe(_ samples: [Float], options: Options = Options()) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw TranscribeError.emptyAudio }
        warnIfEnglishOnlyModel()

        // Serialize the whole ctx-touching region: `whisper_full` plus the
        // segment/language reads run under the Metal lock (project-docs/DECISIONS.md D8).
        // `defer` guarantees the lock is released even on an unexpected throw.
        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        let result = try decodeLocked(
            samples, options: options, whisperVADModel: options.vadModelURL)
        logger.notice(
            "transcription complete; language=\(result.language), segments=\(result.segments.count)")
        return result
    }

    /// Transcribe a recording **split at its VAD speech regions** — the offline
    /// path the refine pass uses.
    ///
    /// Each `SpeechRegion` is decoded as its own `whisper_full` call and its
    /// segment timestamps are shifted back to recording-absolute time. This is
    /// what stops a speaker's turn from being glued into one long segment
    /// across a pause: when the talker goes quiet to listen, the region ends,
    /// so the time-order merge in `RefinementPipeline` can interleave the other
    /// stream's utterances in causal order instead of floating this whole turn
    /// ahead of them.
    ///
    /// Regions come from `detectSpeechRegions(in:vadModelURL:…)`. An empty
    /// `regions` (VAD found no speech) falls back to a plain whole-buffer
    /// decode. whisper's *own* built-in VAD is off for each region decode — the
    /// region already excludes the surrounding silence, and re-running VAD
    /// inside it would only re-concatenate and re-hide any internal gap.
    ///
    /// Same blocking / process-lock contract as `transcribe(_:options:)`.
    public func transcribe(
        _ samples: [Float],
        regions: [SpeechRegion],
        options: Options = Options()
    ) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw TranscribeError.emptyAudio }
        guard !regions.isEmpty else {
            var wholeBuffer = options
            wholeBuffer.vadModelURL = nil   // VAD found no speech to gate on
            return try transcribe(samples, options: wholeBuffer)
        }
        warnIfEnglishOnlyModel()

        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        let sampleCount = samples.count
        var merged: [TranscriptSegment] = []
        var language: String?
        for region in regions {
            let lo = Self.sampleIndex(of: region.start, sampleCount: sampleCount)
            let hi = Self.sampleIndex(of: region.end, sampleCount: sampleCount)
            guard lo < hi else { continue }

            // whisper VAD off (`whisperVADModel: nil`): the region is already
            // speech-only. Shift the region-relative segment times back onto
            // the recording timeline.
            let decoded = try decodeLocked(
                Array(samples[lo..<hi]), options: options, whisperVADModel: nil)
            let offset = Duration.milliseconds(lo * 1000 / AudioFormat.sampleRate)
            for seg in decoded.segments {
                merged.append(TranscriptSegment(
                    start: seg.start + offset,
                    end: seg.end + offset,
                    text: seg.text))
            }
            if language == nil { language = decoded.language }
        }

        logger.notice(
            "transcription complete; \(regions.count) region(s), segments=\(merged.count)")
        return TranscriptionResult(
            segments: merged,
            language: language ?? (isEnglishOnlyModel ? "en" : "unknown"))
    }

    /// Detect the speech regions of a recording with whisper.cpp's bundled
    /// Silero VAD, coalescing regions closer than `minTurnGap` so the transcript
    /// splits at genuine conversational turn pauses rather than at every breath.
    ///
    /// The returned regions feed `transcribe(_:regions:options:)`. They are in
    /// recording-relative time and already carry whisper's `speech_pad_ms`
    /// padding around each detected utterance.
    ///
    /// Runs under the same process-wide Metal lock as `transcribe` — a VAD
    /// context is a ggml context and must not be constructed concurrently with
    /// a `whisper_context` (project-docs/DECISIONS.md D8).
    ///
    /// - Parameters:
    ///   - samples: the whole recording, 16 kHz mono Float32.
    ///   - vadModelURL: a ggml Silero VAD model file.
    ///   - useGPU: VAD backend. Defaults to `false`: the Silero model is tiny,
    ///     a GPU offers no useful speedup, and CPU avoids constructing an extra
    ///     Metal context (project-docs/DECISIONS.md D15).
    ///   - minTurnGap: silence shorter than this between two regions is treated
    ///     as within-turn and the regions are merged. 800 ms matches the
    ///     streaming pipeline's `utteranceGap`.
    public static func detectSpeechRegions(
        in samples: [Float],
        vadModelURL: URL,
        useGPU: Bool = false,
        minTurnGap: Duration = .milliseconds(800),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) throws -> [SpeechRegion] {
        guard !samples.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: vadModelURL.path) else {
            throw TranscribeError.modelNotFound(vadModelURL.path)
        }

        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        var cparams = whisper_vad_default_context_params()
        cparams.use_gpu = useGPU
        guard let vctx = vadModelURL.path.withCString({
            whisper_vad_init_from_file_with_params($0, cparams)
        }) else {
            throw TranscribeError.modelLoadFailed(vadModelURL.path)
        }
        defer { whisper_vad_free(vctx) }

        let vparams = whisper_vad_default_params()
        guard let segments = samples.withUnsafeBufferPointer({ buf in
            whisper_vad_segments_from_samples(
                vctx, vparams, buf.baseAddress, Int32(buf.count))
        }) else {
            throw TranscribeError.transcriptionFailed(-1)
        }
        defer { whisper_vad_free_segments(segments) }

        let n = whisper_vad_segments_n_segments(segments)
        var raw: [SpeechRegion] = []
        raw.reserveCapacity(Int(n))
        for i in 0..<n {
            // The VAD segment getters return `float`, but the value is
            // centiseconds (10 ms units): `whisper_vad_segments_from_samples`
            // stores `samples_to_cs(...)`. This differs from
            // `whisper_full_get_segment_t0`, which is `int64_t` centiseconds.
            let t0 = whisper_vad_segments_get_segment_t0(segments, i)
            let t1 = whisper_vad_segments_get_segment_t1(segments, i)
            raw.append(SpeechRegion(
                start: .milliseconds(Int((Double(t0) * 10).rounded())),
                end: .milliseconds(Int((Double(t1) * 10).rounded()))))
        }

        let coalesced = coalesceRegions(raw, minGap: minTurnGap)
        logger.notice(
            "VAD: \(raw.count) speech region(s) → \(coalesced.count) turn(s)")
        return coalesced
    }

    /// Transcribe one *streaming window* — a short, recent slice of audio —
    /// reusing this object's resident `whisper_context` (Epic 6, R10).
    ///
    /// Unlike `transcribe(_:)` (the offline whole-recording path), this is
    /// called repeatedly on overlapping windows by `StreamingTranscriber`.
    /// Every window is decoded independently (`no_context = true`) so a
    /// hallucinated tail in one window cannot poison the next — the
    /// LocalAgreement-2 committer upstream is what stitches windows into a
    /// stable transcript, not whisper's own cross-window prompting.
    ///
    /// `windowStart` is the window's offset from the start of the *recording*;
    /// it is added to whisper's window-relative segment timestamps so the
    /// returned segments are recording-absolute, exactly like `transcribe(_:)`.
    ///
    /// Deliberately greedy at temperature 0 with no fallback re-decode and no
    /// whisper VAD — unlike the offline `transcribe(_:)`. A streaming window
    /// is short and already VAD-gated upstream by `StreamingTranscriber`, so
    /// the degenerate-decode failure mode `transcribe(_:)` guards against
    /// can't arise here; and LocalAgreement-2 relies on two consecutive
    /// windows decoding their shared audio *identically*, which argmax gives
    /// and sampling would not. `Options.temperature` / `.vadModelURL` are
    /// therefore ignored. Runs under the same process-wide Metal lock (D8).
    public func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: Options = Options()
    ) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw TranscribeError.emptyAudio }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threadCount)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.no_context = true            // each window decoded independently
        // Argmax, no fallback (see the doc comment): LocalAgreement-2 needs
        // overlapping windows to decode their shared audio identically.
        params.temperature = 0
        params.temperature_inc = 0
        params.greedy.best_of = 1
        params.suppress_blank = true
        params.suppress_nst = true
        params.no_speech_thold = options.noSpeechThreshold

        let langString = options.language.flatMap { isEnglishOnlyModel ? nil : $0 }
            ?? (isEnglishOnlyModel ? "en" : "auto")

        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        let code: Int32 = langString.withCString { langPtr -> Int32 in
            params.language = langPtr
            params.detect_language = false
            return runFull(&params, samples)
        }
        guard code == 0 else {
            throw TranscribeError.transcriptionFailed(Int(code))
        }

        let detectedLangId = whisper_full_lang_id(ctx)
        let language = detectedLangId >= 0
            ? String(cString: whisper_lang_str(detectedLangId))
            : (isEnglishOnlyModel ? "en" : "unknown")

        // Window-relative segments, shifted to recording-absolute time.
        let segments = collectSegments().map { seg in
            TranscriptSegment(
                start: seg.start + windowStart,
                end: seg.end + windowStart,
                text: seg.text)
        }
        return TranscriptionResult(segments: segments, language: language)
    }

    // MARK: - Private

    /// Decode one contiguous buffer with the offline param profile (greedy +
    /// temperature fallback) and return its **buffer-relative** segments. The
    /// caller must already hold `metalLock`.
    ///
    /// `whisperVADModel`, when non-nil, enables whisper.cpp's built-in Silero
    /// VAD for this decode (the whole-buffer path). The region-split path
    /// passes `nil`: each region is already speech-only, and re-running VAD
    /// inside it would only re-concatenate and re-hide any internal gap.
    private func decodeLocked(
        _ samples: [Float],
        options: Options,
        whisperVADModel: URL?
    ) throws -> TranscriptionResult {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threadCount)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.no_context = true            // offline: each run is independent
        // Temperature + fallback. whisper.cpp seeds its sampler RNG with a
        // fixed per-call constant, so a non-zero temperature is still
        // reproducible; `temperature_inc` lets a window that fails whisper's
        // quality checks re-decode hotter instead of its garbage tokens
        // poisoning every later window in this same `whisper_full` call.
        params.temperature = options.temperature
        params.temperature_inc = options.temperatureFallbackStep
        params.greedy.best_of = 1
        // Hallucination suppression (Epic 2 edge case): drop blank/non-speech
        // tokens at the decoder, and gate on the no-speech probability.
        params.suppress_blank = true
        params.suppress_nst = true
        params.no_speech_thold = options.noSpeechThreshold

        // The chosen language string: a forced code, "en" for an *.en model,
        // or "auto" for multilingual auto-detect.
        let langString = options.language.flatMap { isEnglishOnlyModel ? nil : $0 }
            ?? (isEnglishOnlyModel ? "en" : "auto")

        // Decode under the (forced/auto) language. A nested func so it can be
        // invoked either directly or nested inside the VAD-path `withCString`
        // below; it captures the local `var params` by reference, so the
        // `vad_*` / `language` fields set just before the call are seen by
        // `runFull`. `decode()` must not escape this stack frame — it borrows
        // `params` and `samples` by reference.
        //
        // C-string lifetime: `params.language` and (caller-set)
        // `params.vad_model_path` are borrowed `withCString` pointers, valid
        // only inside their closures. That is sufficient: `whisper_full` takes
        // `whisper_full_params` *by value*, so it copies the struct — and
        // dereferences those pointers — entirely within the `runFull` call,
        // before any `withCString` closure unwinds. Keep each `runFull` call
        // nested inside the closures that own the pointers it reads.
        func decode() -> Int32 {
            langString.withCString { langPtr -> Int32 in
                params.language = langPtr
                params.detect_language = false  // whisper_full auto-detects on "auto"
                return runFull(&params, samples)
            }
        }

        // whisper.cpp's built-in Silero VAD, when a model is supplied: it
        // drops non-speech regions before decoding, so a long digital-silence
        // stretch can't push the greedy decoder into a degenerate loop.
        // whisper maps the segment timestamps back to original-audio time
        // internally, so `collectSegments()` needs no adjustment.
        let code: Int32
        if let whisperVADModel {
            params.vad = true
            params.vad_params = whisper_vad_default_params()
            code = whisperVADModel.path.withCString { vadPtr -> Int32 in
                params.vad_model_path = vadPtr
                return decode()
            }
        } else {
            code = decode()
        }
        guard code == 0 else {
            throw TranscribeError.transcriptionFailed(Int(code))
        }

        let detectedLangId = whisper_full_lang_id(ctx)
        let language = detectedLangId >= 0
            ? String(cString: whisper_lang_str(detectedLangId))
            : (isEnglishOnlyModel ? "en" : "unknown")
        return TranscriptionResult(segments: collectSegments(), language: language)
    }

    /// Log the `*.en`-model-on-arbitrary-audio warning (Epic 2 edge case). We
    /// default to a multilingual model, so this is only ever a warning path.
    private func warnIfEnglishOnlyModel() {
        if isEnglishOnlyModel {
            logger.warning(
                "english-only whisper model in use; non-English speech will be mis-transcribed")
        }
    }

    /// Merge speech regions separated by less than `minGap` so the transcript
    /// breaks at genuine turn pauses, not at every short breath. `regions` must
    /// be in ascending start order; the result is too.
    static func coalesceRegions(
        _ regions: [SpeechRegion],
        minGap: Duration
    ) -> [SpeechRegion] {
        guard var current = regions.first else { return [] }
        var out: [SpeechRegion] = []
        for region in regions.dropFirst() {
            if region.start - current.end < minGap {
                current = SpeechRegion(
                    start: current.start,
                    end: max(current.end, region.end))
            } else {
                out.append(current)
                current = region
            }
        }
        out.append(current)
        return out
    }

    /// Clamp a recording-relative time to a valid sample index in `[0, count]`.
    private static func sampleIndex(of time: Duration, sampleCount: Int) -> Int {
        let idx = Int((time.seconds * Double(AudioFormat.sampleRate)).rounded())
        return min(max(idx, 0), sampleCount)
    }

    private func runFull(_ params: inout whisper_full_params, _ samples: [Float]) -> Int32 {
        samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
    }

    /// Pull segments out of the resident context, filtering blank ones.
    private func collectSegments() -> [TranscriptSegment] {
        let n = whisper_full_n_segments(ctx)
        var out: [TranscriptSegment] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            guard let raw = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !BlankTokenFilter.isBlank(text) else { continue }
            // whisper timestamps are in centiseconds (10 ms units).
            let t0 = whisper_full_get_segment_t0(ctx, i)
            let t1 = whisper_full_get_segment_t1(ctx, i)
            out.append(TranscriptSegment(
                start: .milliseconds(Int(t0) * 10),
                end: .milliseconds(Int(t1) * 10),
                text: text
            ))
        }
        return out
    }
}
