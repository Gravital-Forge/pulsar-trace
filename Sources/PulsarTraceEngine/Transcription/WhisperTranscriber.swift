import Foundation
import CWhisper
import Logging

/// Offline transcription via whisper.cpp's C API (R9).
///
/// One `WhisperTranscriber` owns exactly one `whisper_context`, loaded once at
/// init and kept resident for the object's lifetime — no per-call model reload,
/// no `whisper-cli` subprocess. The model file is loaded with Metal
/// acceleration enabled (the library is built `-DGGML_METAL=ON`).
///
/// The offline path uses `transcribe(_:)`: it takes the *whole* recording as
/// one contiguous Float32 buffer and makes a single `whisper_full` call. With
/// no chunking there are no chunk-boundary artifacts, which satisfies R11 for
/// the offline path. The live pass instead drives `transcribeWindow(_:)`
/// repeatedly on overlapping windows.
///
/// Decoding (`transcribe(_:)`): greedy sampling with a small temperature and
/// whisper's temperature fallback enabled — a window that fails whisper's
/// quality checks is re-decoded hotter instead of its garbage tokens
/// poisoning every later window in the same `whisper_full` call. whisper.cpp
/// seeds its sampler RNG with a fixed per-call constant (`std::mt19937(0)`),
/// so output is still byte-reproducible run-to-run on a given build. An
/// optional Silero VAD model drops non-speech regions before decoding so a
/// long digital-silence stretch can't drive the decoder into that degenerate
/// state in the first place. See `WhisperOptions`.
///
/// Not `Sendable`: `whisper_context` is not thread-safe. Use one transcriber
/// per source from a single task.
///
/// Metal serialization: whisper.cpp's Metal backend keeps a per-device
/// residency set that asserts (`GGML_ASSERT(rsets->data count == 0)`) if two
/// `whisper_context`s are constructed/freed concurrently in one process. The
/// common case is one source = one transcriber, but the engine is a long-lived
/// process and nothing stops a caller (re-refine, tests) from holding two at
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
public final class WhisperTranscriber: WindowTranscribing, RegionTranscribing {

    /// Guards `whisper_context` lifecycle and `whisper_full` across the
    /// process so the Metal backend never sees concurrent contexts.
    private static let metalLock = NSLock()

    /// Per-segment token cap for the streaming window path (whisper.h `max_tokens`).
    /// Bounds a degenerate/runaway decode. 0 = unlimited (old behavior).
    static let streamingMaxTokensPerSegment = 256

    private let ctx: OpaquePointer
    private let modelURL: URL
    private let logger: Logger
    /// True when the model file name marks an English-only model (`*.en`).
    private let isEnglishOnlyModel: Bool

    /// Load a ggml whisper model file and keep it resident.
    ///
    /// - Parameters:
    ///   - modelURL: a `ggml-*.bin` file (`base`, `large-v3`, …).
    ///   - useGPU: loads the model on the Metal backend (production) when
    ///     `true`, or whisper's CPU backend when `false`. Defaults to
    ///     `WhisperOptions.defaultGPUEnabled` — GPU unless `PULSARTRACE_WHISPER_CPU` is set.
    ///     The test/CI suite passes `false` explicitly so it never touches the
    ///     ggml-metal device and so cannot trip the upstream exit-time
    ///     residency-set assertion (project-docs/DECISIONS.md D15).
    public init(
        modelURL: URL,
        useGPU: Bool = WhisperOptions.defaultGPUEnabled,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) throws {
        self.modelURL = modelURL
        self.logger = logger
        self.isEnglishOnlyModel =
            modelURL.deletingPathExtension().lastPathComponent.hasSuffix(".en")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperTranscribeError.modelNotFound(modelURL.path)
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
            throw WhisperTranscribeError.modelLoadFailed(modelURL.path)
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
    public func transcribe(_ samples: [Float], options: WhisperOptions = WhisperOptions()) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw WhisperTranscribeError.emptyAudio }
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
        options: WhisperOptions = WhisperOptions()
    ) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw WhisperTranscribeError.emptyAudio }
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

    /// Decode one VAD region as a single `whisper_full` call, with timestamps
    /// shifted onto the recording timeline.
    ///
    /// Intended for callers that iterate regions externally — e.g.
    /// `ResumableRefiner` (D-Q6), which persists a checkpoint between regions
    /// and honours a pause gate. Each call acquires `metalLock` independently,
    /// so the pause gate can fire between consecutive regions. This is the
    /// public contract that `transcribe(_:regions:options:)` implements
    /// internally (with the lock already held for the whole batch).
    ///
    /// Same blocking / process-lock contract as `transcribe(_:options:)`.
    ///
    /// - Parameters:
    ///   - samples: the whole recording, 16 kHz mono Float32.
    ///   - region: the speech region to decode, in recording-relative time.
    ///   - options: decoder tunables; `options.vadModelURL` is ignored — the
    ///     region is already speech-only.
    public func transcribeRegion(
        _ samples: [Float],
        region: SpeechRegion,
        options: WhisperOptions = WhisperOptions()
    ) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw WhisperTranscribeError.emptyAudio }
        warnIfEnglishOnlyModel()

        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        let sampleCount = samples.count
        let lo = Self.sampleIndex(of: region.start, sampleCount: sampleCount)
        let hi = Self.sampleIndex(of: region.end, sampleCount: sampleCount)
        guard lo < hi else {
            return TranscriptionResult(
                segments: [],
                language: isEnglishOnlyModel ? "en" : "unknown")
        }

        // whisper VAD off (`whisperVADModel: nil`): the region is already
        // speech-only. Shift the region-relative segment times back onto
        // the recording timeline.
        let decoded = try decodeLocked(
            Array(samples[lo..<hi]), options: options, whisperVADModel: nil)
        let offset = Duration.milliseconds(lo * 1000 / AudioFormat.sampleRate)
        let shifted = decoded.segments.map { seg in
            TranscriptSegment(
                start: seg.start + offset,
                end: seg.end + offset,
                text: seg.text)
        }
        return TranscriptionResult(
            segments: shifted,
            language: decoded.language)
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
            throw WhisperTranscribeError.modelNotFound(vadModelURL.path)
        }

        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        var cparams = whisper_vad_default_context_params()
        cparams.use_gpu = useGPU
        guard let vctx = vadModelURL.path.withCString({
            whisper_vad_init_from_file_with_params($0, cparams)
        }) else {
            throw WhisperTranscribeError.modelLoadFailed(vadModelURL.path)
        }
        defer { whisper_vad_free(vctx) }

        let vparams = whisper_vad_default_params()
        guard let segments = samples.withUnsafeBufferPointer({ buf in
            whisper_vad_segments_from_samples(
                vctx, vparams, buf.baseAddress, Int32(buf.count))
        }) else {
            throw WhisperTranscribeError.transcriptionFailed(-1)
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

        let coalesced = SpeechRegion.coalesced(raw, minGap: minTurnGap)
        logger.notice(
            "VAD: \(raw.count) speech region(s) → \(coalesced.count) turn(s)")
        return coalesced
    }

    /// Transcribe one *streaming window* — a short, recent slice of audio —
    /// reusing this object's resident `whisper_context` (R10).
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
    /// and sampling would not. `WhisperOptions.temperature` / `.vadModelURL` are
    /// therefore ignored. Runs under the same process-wide Metal lock (D8).
    public func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperOptions = WhisperOptions(),
        abort: AbortToken? = nil
    ) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw WhisperTranscribeError.emptyAudio }

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

        // Per-segment token cap: a window is ≤ 8 s of speech, so a few hundred
        // tokens is generous; an unbounded (0) cap lets a degenerate decode
        // loop spin. Bounds a runaway even between abort polls.
        params.max_tokens = Int32(Self.streamingMaxTokensPerSegment)

        // Abort hook: a watchdog on another task flips `abort.cancel()`; whisper
        // polls this at each encode/decode-step boundary (this build checks it
        // after every `whisper_encode_internal` / `whisper_decode_internal`, not
        // between individual ggml graph nodes — verified in vendor/whisper.cpp)
        // and returns early, skipping the rest of the decode and releasing
        // metalLock. The closure is @convention(c) (no captures) and reads the
        // token through the user-data pointer.
        if let abort {
            let cb: ggml_abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<AbortToken>
                    .fromOpaque(userData).takeUnretainedValue().isCancelled
            }
            params.abort_callback = cb
            params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        }

        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        let langString = resolveLanguageStringLocked(
            samples: samples, options: options)

        let code: Int32 = langString.withCString { langPtr -> Int32 in
            params.language = langPtr
            params.detect_language = false
            return runFull(&params, samples)
        }
        guard code == 0 else {
            throw WhisperTranscribeError.transcriptionFailed(Int(code))
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
        options: WhisperOptions,
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
        // Hallucination suppression: drop blank/non-speech
        // tokens at the decoder, and gate on the no-speech probability.
        params.suppress_blank = true
        params.suppress_nst = true
        params.no_speech_thold = options.noSpeechThreshold

        // The chosen language string: a forced code, "en" for an *.en model,
        // an allow-list pre-detect pick, or "auto" for unrestricted
        // multilingual auto-detect. See `resolveLanguageStringLocked` for the
        // branch order — the helper already holds the metalLock invariant.
        let langString = resolveLanguageStringLocked(
            samples: samples, options: options)

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
            throw WhisperTranscribeError.transcriptionFailed(Int(code))
        }

        let detectedLangId = whisper_full_lang_id(ctx)
        let language = detectedLangId >= 0
            ? String(cString: whisper_lang_str(detectedLangId))
            : (isEnglishOnlyModel ? "en" : "unknown")
        // Offline path: drop silence hallucinations whisper decoded
        // confidently as a stock phrase (`HallucinationFilter`, D31). Scoped
        // to this offline decode — `transcribeWindow` keeps the raw segments.
        return TranscriptionResult(
            segments: collectSegments(dropHallucinations: true), language: language)
    }

    /// Log the `*.en`-model-on-arbitrary-audio warning. We
    /// default to a multilingual model, so this is only ever a warning path.
    private func warnIfEnglishOnlyModel() {
        if isEnglishOnlyModel {
            logger.warning(
                "english-only whisper model in use; non-English speech will be mis-transcribed")
        }
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
    ///
    /// - Parameter dropHallucinations: when `true` (the offline / refine
    ///   path), a segment whose text is a known whisper silence-hallucination
    ///   stock phrase *and* whose per-segment confidence signals say the audio
    ///   is silence is dropped (`HallucinationFilter`, project-docs/DECISIONS.md
    ///   D31). `false` (the streaming `transcribeWindow` path) keeps every
    ///   non-blank segment — see D31 for why streaming is out of scope.
    private func collectSegments(
        dropHallucinations: Bool = false
    ) -> [TranscriptSegment] {
        let n = whisper_full_n_segments(ctx)
        var out: [TranscriptSegment] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            guard let raw = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !BlankTokenFilter.isBlank(text) else { continue }

            // Offline only: a confidently-decoded stock phrase on silence
            // (e.g. a hallucinated "Thank you.") is dropped. Gated on an
            // objective per-segment signal so a real short utterance — which
            // has a low no_speech_prob and a healthy avg logprob — survives.
            if dropHallucinations {
                let confidence = HallucinationFilter.SegmentConfidence(
                    noSpeechProb: whisper_full_get_segment_no_speech_prob(ctx, i),
                    avgLogProb: Self.segmentAvgLogProb(ctx, segment: i))
                if HallucinationFilter.shouldDrop(text: text, confidence: confidence) {
                    logger.notice(
                        "dropped silence hallucination: no_speech_prob=\(confidence.noSpeechProb), avg_logprob=\(confidence.avgLogProb)")
                    continue
                }
            }

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

    /// Argmax of `probs` restricted to the subset of `allowed` codes that
    /// `idForCode` resolves to a valid index. Returns `nil` when no allowed
    /// code resolves (caller's policy: fall back to unrestricted auto).
    ///
    /// Pure (no whisper-context dependency) so the lookup table can be
    /// stubbed in tests. The real caller passes a closure over
    /// `whisper_lang_id(_:)`.
    static func pickAllowedLanguage(
        probs: [Float],
        allowed: [String],
        idForCode: (String) -> Int?
    ) -> String? {
        var best: (code: String, score: Float)?
        for code in allowed {
            guard let id = idForCode(code), id >= 0, id < probs.count else {
                continue
            }
            let score = probs[id]
            if best == nil || score > best!.score {
                best = (code, score)
            }
        }
        return best?.code
    }

    /// Resolve the language string to hand to `whisper_full` for a given
    /// audio buffer. Three branches:
    ///   1. English-only model → always `"en"` (model only supports English).
    ///   2. `options.language` set → forced (caller-pinned).
    ///   3. `options.allowedLanguages` non-empty → pre-detect via
    ///      `whisper_pcm_to_mel` + `whisper_lang_auto_detect`, argmax over
    ///      the allowed subset.
    ///   4. Default → `"auto"` (legacy whisper auto-detect inside
    ///      `whisper_full`).
    ///
    /// Caller must already hold `metalLock`. Mutates the resident context's
    /// default state (mel + encoder) when (3) runs; that is fine because
    /// `whisper_full` resets state at entry.
    func resolveLanguageStringLocked(
        samples: [Float],
        options: WhisperOptions
    ) -> String {
        if isEnglishOnlyModel { return "en" }
        if let forced = options.language { return forced }
        let allowed = options.allowedLanguages
        guard !allowed.isEmpty else { return "auto" }

        // Pre-pass: encode the mel + run whisper's built-in language
        // detector, then pick the argmax restricted to the allow list.
        let melCode = samples.withUnsafeBufferPointer { buf in
            whisper_pcm_to_mel(
                ctx, buf.baseAddress, Int32(buf.count),
                Int32(options.threadCount))
        }
        if melCode != 0 {
            logger.warning(
                "language pre-detect: whisper_pcm_to_mel returned \(melCode); falling back to auto")
            return "auto"
        }
        let maxId = Int(whisper_lang_max_id())
        var probs = [Float](repeating: 0, count: maxId + 1)
        let topId = probs.withUnsafeMutableBufferPointer { buf -> Int32 in
            whisper_lang_auto_detect(
                ctx, 0, Int32(options.threadCount), buf.baseAddress)
        }
        if topId < 0 {
            logger.warning(
                "language pre-detect: whisper_lang_auto_detect returned \(topId); falling back to auto")
            return "auto"
        }
        let picked = Self.pickAllowedLanguage(
            probs: probs,
            allowed: allowed,
            idForCode: { code in
                let id = whisper_lang_id(code)
                return id >= 0 ? Int(id) : nil
            })
        return picked ?? "auto"
    }

    /// Mean per-token log-probability across a segment's tokens.
    ///
    /// whisper.cpp exposes only per-token probability `p` (and `plog`); it has
    /// no segment-level avg-logprob getter. We average the token `plog`s
    /// (`whisper_token_data.plog`) ourselves. An empty segment returns `0`
    /// (treated as fully confident — the silence gate falls back to
    /// `no_speech_prob` alone).
    private static func segmentAvgLogProb(
        _ ctx: OpaquePointer, segment i: Int32
    ) -> Float {
        let tokenCount = whisper_full_n_tokens(ctx, i)
        guard tokenCount > 0 else { return 0 }
        var sum: Float = 0
        for t in 0..<tokenCount {
            sum += whisper_full_get_token_data(ctx, i, t).plog
        }
        return sum / Float(tokenCount)
    }
}
