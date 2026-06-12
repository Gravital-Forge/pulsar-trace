import Foundation
import Logging
import WhisperKit
// Scoped import: the umbrella `Accelerate` also re-exports `os`, whose
// `os.Logger` collides with swift-log's `Logging.Logger` used here. Import
// just `vDSP` so the namespace stays clean.
import enum Accelerate.vDSP

/// The ANE refinement transcriber: Whisper large-v3-turbo (or full
/// large-v3) via WhisperKit, encoder + decoder on `.cpuAndNeuralEngine`.
/// Replaces the `pulsartrace-whisper` Metal subprocess on the refine path —
/// in-process, no flock, no Metal lock, GPU untouched.
///
/// An actor: WhisperKit's top-level class is not Sendable (v1.0.0 release
/// note) and keeps per-instance mutable state. The actor serializes *state*
/// access, but actors are reentrant across `await`, so the actor alone does
/// not stop two public decodes from interleaving mid-`transcribe` and driving
/// the non-Sendable WhisperKit instance concurrently. The explicit
/// non-reentrant decode lock (below) serializes whole decodes across their
/// suspension points — matching the refine queue's single-worker invariant
/// anyway, while keeping the public batch loop fair region-by-region.
///
/// Lazy load: construction is cheap and synchronous (so the queue's
/// `SharedTranscriberBox` can hold it); the model loads on the first decode.
/// Dropping the actor (the queue's pause-release hook) frees the CoreML
/// models via ARC — the in-process analogue of SIGTERMing the subprocess.
///
/// Wedge recovery: the old design SIGKILLed a wedged Metal decode. Here the
/// per-token `TranscriptionCallback` returns `false` once the deadline
/// passes, which makes WhisperKit stop decoding — no process to kill. That
/// only bounds decodes that still emit tokens: a hard CoreML hang inside a
/// single `predict` (no token callbacks — including the detect pre-pass and
/// prewarm/load) cannot be recovered in-process. That is the accepted risk of
/// dropping the subprocess design; the refine queue's job-level handling owns
/// that failure mode.
///
/// Language (Delta B / `WhisperKitLanguagePolicy`), resolved per decode:
/// explicit pin → forced language token; one allowed code → pin; several →
/// detect on the slice, pin the best **allowed** code; none → auto.
public actor WhisperKitRegionTranscriber {

    public struct Configuration: Sendable {
        /// Which WhisperKit variant to load (`WhisperKitModelCatalog`).
        public var model: WhisperKitModel
        /// Hub root for model + tokenizer downloads — keep it under
        /// `<models cache root>/whisperkit` (D10/D39). The variant lands at
        /// `models/argmaxinc/whisperkit-coreml/<variant>`.
        public var downloadBase: URL
        /// Minimum wall-clock budget per decode call. The effective budget
        /// is `max(decodeDeadline, decoded-audio duration)` so a 1 h
        /// whole-buffer fallback isn't killed at 120 s while still bounding
        /// a wedged short-region decode like the old subprocess deadline.
        public var decodeDeadline: Duration

        public init(
            model: WhisperKitModel,
            downloadBase: URL,
            decodeDeadline: Duration = .seconds(120)
        ) {
            self.model = model
            self.downloadBase = downloadBase
            self.decodeDeadline = decodeDeadline
        }
    }

    /// SDK adaptation: WhisperKit's top-level class is a plain `open class`
    /// (not `Sendable`, v1.0.0), so a `Task<WhisperKit, Error>` cannot return
    /// its value across the Task→actor boundary under Swift 6 checking — the
    /// memoized-Task pattern needs a hand-carry box. Sound because the only
    /// code that creates or touches the `WhisperKit` instance is this actor:
    /// the load Task constructs it, every decode calls `pipe.transcribe` /
    /// `pipe.detectLangauge` from actor-isolated context, and the box never
    /// escapes. (WhisperKit applies the same `@unchecked Sendable` discipline
    /// to its own `TranscriptionResult`.)
    private final class Box: @unchecked Sendable {
        let pipe: WhisperKit
        init(_ pipe: WhisperKit) { self.pipe = pipe }
    }

    private let configuration: Configuration
    private let events: EventWriter?
    private let logger: Logger
    /// Deviation B: memoized load task (mirrors `FluidVADRegionDetector`'s
    /// `managerTask`). A failed load clears the slot so the caller's retry
    /// contract can re-attempt; a successful load is cached for the actor's
    /// lifetime. Carries `Box` (not `WhisperKit`) for the Sendable reason
    /// above.
    private var pipeTask: Task<Box, Error>?

    // MARK: - Non-reentrant decode lock
    //
    // Actors are reentrant across `await`, so without this two public calls
    // could interleave mid-decode and drive the non-Sendable WhisperKit
    // instance concurrently. FIFO waiter queue; the resumed waiter inherits
    // the lock.
    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireDecodeLock() async {
        if decodeBusy {
            await withCheckedContinuation { decodeWaiters.append($0) }
        } else {
            decodeBusy = true
        }
    }

    private func releaseDecodeLock() {
        if decodeWaiters.isEmpty {
            decodeBusy = false
        } else {
            decodeWaiters.removeFirst().resume()
        }
    }

    /// Records whether the per-token deadline callback actually fired. Testing
    /// the callback's decision (not the clock, post-decode) avoids failing a
    /// decode that finished naturally just inside budget — the clock can cross
    /// the deadline between the last token and a post-hoc `Date()` check.
    private final class DeadlineFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func markFired() { lock.lock(); fired = true; lock.unlock() }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// A one-way "stop this decode" flag the per-token callback observes. Set
    /// from outside the actor's isolation (`cancelPending()`), so it is an
    /// NSLock-guarded class — the same shape as `DeadlineFlag` — rather than
    /// actor-isolated state a non-isolated caller couldn't reach. Sticky: once
    /// fired it stays fired, so the *instance* is dead after a cancel (every
    /// later `decode` on it throws). The queue's pause/release path builds a
    /// fresh transcriber for the next job, so a poisoned instance is never reused.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func markFired() { lock.lock(); fired = true; lock.unlock() }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// `nonisolated` so the queue's release hook can flip it without hopping
    /// onto the actor — which is the whole point: a cancel must land even while
    /// the actor is parked inside an in-flight `pipe.transcribe`. The decode
    /// observes it at the next token boundary and unwinds.
    private nonisolated let cancelFlag = CancelFlag()

    public init(
        configuration: Configuration,
        events: EventWriter?,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.configuration = configuration
        self.events = events
        self.logger = logger
    }

    deinit {
        // Best-effort: cancelling a still-in-flight load lets WhisperKit's
        // downloader stop at the next file boundary rather than finishing a
        // download whose actor is already gone. Harmless once loaded.
        // Direct stored-property access is legal in an actor `deinit` (no
        // awaits) under Swift 6.
        pipeTask?.cancel()
    }

    // MARK: - Decode API (the refine seam)

    /// Stop the in-flight decode at the next token boundary. The current
    /// `pipe.transcribe` callback returns `false` (WhisperKit stops emitting
    /// tokens), and `decode` then throws `CancellationError` rather than a
    /// result — propagating straight out of the refiner (it is not a
    /// `TranscriptionError`, so the per-region retry loop does not catch it),
    /// which exits the refinement worker. This is the in-process analogue of
    /// SIGTERMing the old `pulsartrace-whisper` subprocess on a recording start.
    ///
    /// `nonisolated`: callable while the actor is parked inside a decode (an
    /// actor-isolated hop would deadlock behind the very decode we want to stop).
    /// Sticky: this instance is *dead* after a cancel — every later `decode` on
    /// it throws at entry. The queue builds a fresh transcriber per job, so a
    /// cancelled instance is never reused (pause releases the box; the next job
    /// rebuilds it).
    public nonisolated func cancelPending() {
        cancelFlag.markFired()
    }

    /// Decode one VAD region; segment timestamps come back recording-absolute
    /// — the same contract as the old `WhisperTranscriber.transcribeRegion`.
    public func transcribeRegion(
        _ samples: [Float],
        region: SpeechRegion,
        options: TranscriptionOptions
    ) async throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }
        let sampleCount = samples.count
        let lo = Self.sampleIndex(of: region.start, sampleCount: sampleCount)
        let hi = Self.sampleIndex(of: region.end, sampleCount: sampleCount)
        guard lo < hi else {
            return TranscriptionResult(
                segments: [], language: Self.degenerateLanguage(options))
        }
        return try await decode(
            Array(samples[lo..<hi]),
            shiftedBy: .milliseconds(lo * 1000 / AudioFormat.sampleRate),
            options: options)
    }

    /// Batch entry: decode every region; `regions == []` falls back to a
    /// whole-buffer decode (mirrors the old `transcribe(_:regions:)` —
    /// WhisperKit's internal 30 s seek loop handles arbitrary lengths).
    public func transcribe(
        _ samples: [Float],
        regions: [SpeechRegion],
        options: TranscriptionOptions
    ) async throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }
        guard !regions.isEmpty else {
            return try await decode(samples, shiftedBy: .zero, options: options)
        }
        var merged: [TranscriptSegment] = []
        var language: String?
        for region in regions {
            let result = try await transcribeRegion(
                samples, region: region, options: options)
            merged.append(contentsOf: result.segments)
            // First non-"unknown" region wins the summary field; under
            // detect-among, later regions may legitimately pin a different
            // code. This field is advisory — per-segment correctness (each
            // region decoded with its own pin) is what actually matters.
            if language == nil, result.language != "unknown" {
                language = result.language
            }
        }
        return TranscriptionResult(
            segments: merged, language: language ?? "unknown")
    }

    // MARK: - Internals

    private func decode(
        _ slice: [Float],
        shiftedBy offset: Duration,
        options: TranscriptionOptions
    ) async throws -> TranscriptionResult {
        // Serialize the whole decode (ensureLoaded + detect + transcribe) as
        // one critical section. The actor alone can't: it's reentrant across
        // `await`, so a second public call could interleave mid-decode and
        // drive the non-Sendable WhisperKit instance concurrently. Acquire
        // first; the immediate `defer` releases on every throw path.
        await acquireDecodeLock()
        defer { releaseDecodeLock() }

        // Cancel gate (entry). If the queue's release hook already fired
        // `cancelPending()` — recording start while this job was mid-decode —
        // bail before touching the model. The instance is now poisoned; every
        // later decode on it throws here too (the queue rebuilds a fresh one).
        //
        // Cancel is observed at four points so a recording start unwinds
        // promptly regardless of where the decode is: (1) here at entry, (2)
        // immediately after `ensureLoaded()` below — a cancel that lands during a
        // long model load / prewarm would otherwise be blind until the first
        // token callback, and in the `.detectAmong` case would let an entire
        // uncancelled `pipe.detectLangauge` encoder pass run first, (3) per token
        // in the `pipe.transcribe` callback, and (4) post-decode before returning.
        if cancelFlag.didFire { throw CancellationError() }

        // Pre-decode digital-silence guard (D31). The legacy whisper.cpp path
        // dropped silent regions *inside* `whisper_full` via its built-in
        // Silero VAD before any tokens were sampled; on the WhisperKit backend
        // that VAD has moved upstream (`FluidVADRegionDetector`), so a region
        // of (near-)zero energy handed straight to this actor would otherwise
        // be decoded by WhisperKit — which confidently hallucinates a stock
        // phrase on pure-zero input (observed: `" Thank you."` with
        // noSpeechProb=0.0, avgLogprob=-0.13, so BOTH WhisperKit's own
        // no-speech gate AND the D31 `HallucinationFilter` confidence gate are
        // bypassed). An objective energy measurement is the only signal that
        // survives the decoder lying, and it can never drop a real utterance:
        // genuine speech is orders of magnitude above this floor, while
        // digital silence / dead air sits at ~0.
        if Self.isDigitalSilence(slice) {
            logger.notice("whisperkit: region is digital silence — skipping decode")
            return TranscriptionResult(
                segments: [], language: Self.degenerateLanguage(options))
        }

        let pipe = try await ensureLoaded()

        // Cancel gate (post-load). The load/prewarm above can take seconds; a
        // recording-start `cancelPending()` that landed during it would be blind
        // until the first `pipe.transcribe` token callback. Worse, in the
        // `.detectAmong` branch below a whole uncancelled `pipe.detectLangauge`
        // encoder pass would run first. Observe the cancel here so neither
        // happens — bail before the detect pre-pass and the decode.
        if cancelFlag.didFire { throw CancellationError() }

        var decodeOptions = DecodingOptions()
        decodeOptions.task = .transcribe

        // Start the budget clock *before* the language-resolution switch so a
        // `detectAmong` pre-pass is charged to the same deadline (the
        // transcribe callback below then has correspondingly less). Without
        // this, detect time was unbounded and uncounted.
        let budgetSeconds = max(
            configuration.decodeDeadline.seconds,
            Double(slice.count) / Double(AudioFormat.sampleRate))
        let deadline = Date().addingTimeInterval(budgetSeconds)

        // Language resolution (Delta B), per region decode. With prefill on
        // (default) and detectLanguage off, WhisperKit force-feeds the
        // `<|pl|>`/`<|en|>` token.
        let resolution = WhisperKitLanguagePolicy.resolve(
            explicit: options.language, allowed: options.allowedLanguages)
        let pinnedLanguage: String?
        switch resolution {
        case .pin(let code):
            pinnedLanguage = code
        case .auto:
            pinnedLanguage = nil
        case .detectAmong(let codes):
            // WhisperKit's array-overload detection — note the upstream
            // method-name typo ("Langauge"), verified v1.0.0
            // Sources/WhisperKit/Core/WhisperKit.swift:534. Uses the first
            // 30 s of the slice internally; langProbs is keyed by ISO code.
            //
            // SDK adaptation: `langProbs` is a **sparse log-probability**
            // map, not a full distribution — WhisperKit's
            // `TextDecoder.detectLanguage` only records an entry for the
            // language token(s) it actually sampled (verified v1.0.0
            // TextDecoder.swift:508-514), and the values are log-probs (≤ 0,
            // ~0 for the argmax). An *absent* allowed code therefore means
            // "scored lowest", so it must default to `-.infinity`, NOT `0`
            // (the spec's `?? 0` would make an unscored code outrank the
            // genuinely-detected one — on an English slice `langProbs =
            // ["en": -0.0002]`, and `pl` absent → 0 > -0.0002 → wrongly pins
            // "pl"). `-.infinity` keeps the genuinely-detected argmax winning.
            let (_, langProbs) = try await pipe.detectLangauge(audioArray: slice)
            let best = codes.max {
                (langProbs[$0] ?? -.infinity) < (langProbs[$1] ?? -.infinity)
            } ?? codes[0]
            logger.notice("whisperkit: detect-among \(codes) → \(best)")
            pinnedLanguage = best
        }
        decodeOptions.language = pinnedLanguage
        decodeOptions.detectLanguage = pinnedLanguage == nil

        // Deterministic-first decode with whisper's own fallback ladder —
        // the D25 posture, expressed in WhisperKit terms.
        decodeOptions.temperature = 0
        decodeOptions.temperatureIncrementOnFallback = 0.2
        decodeOptions.temperatureFallbackCount = 5
        decodeOptions.skipSpecialTokens = true
        // WhisperKit defaults suppressBlank to false (OpenAI reference
        // defaults it true) — set it for parity with the old path.
        decodeOptions.suppressBlank = true
        decodeOptions.noSpeechThreshold = options.noSpeechThreshold
        // No chunkingStrategy: regions are already speech-only slices; long
        // slices use WhisperKit's sequential seek loop.

        // Record the callback's *actual* decision rather than re-reading the
        // clock after `transcribe` returns: a post-hoc `Date() >= deadline`
        // can fail a decode that finished naturally just inside budget if the
        // clock crosses the line between the last token and the check.
        let flag = DeadlineFlag()
        let cancelFlag = self.cancelFlag
        let callback: TranscriptionCallback = { _ in
            // Cancel wins over the deadline: a recording-start release must stop
            // the decode promptly, and the post-decode check below distinguishes
            // the two outcomes (CancellationError vs decodeDeadlineExceeded).
            if cancelFlag.didFire { return false }
            if Date() < deadline { return nil }
            flag.markFired()
            return false   // stop decoding
        }

        let results = try await pipe.transcribe(
            audioArray: slice, decodeOptions: decodeOptions, callback: callback)
        // Cancel takes precedence: a release fired mid-decode means the worker
        // is unwinding for a recording start. Throw `CancellationError` (NOT a
        // `TranscriptionError`) so `ResumableRefiner`'s per-region retry
        // loop does not catch it — it propagates out and exits the worker,
        // mirroring the old IPC-EOF propagation when the subprocess was killed.
        if cancelFlag.didFire { throw CancellationError() }
        if flag.didFire {
            // Deviation A: a budget overrun is a deadline, not a
            // whisper_full(-2). Throw the truthful case.
            logger.error("whisperkit decode exceeded \(Int(budgetSeconds))s budget — treating as failed")
            throw TranscriptionError.decodeDeadlineExceeded
        }

        let inputs = results.flatMap(\.segments).map {
            WhisperKitSegmentMapper.InputSegment(
                text: $0.text, start: $0.start, end: $0.end,
                noSpeechProb: $0.noSpeechProb, avgLogprob: $0.avgLogprob)
        }
        let segments = WhisperKitSegmentMapper.segments(
            from: inputs, shiftedBy: offset, dropHallucinations: true)
        // Deviation C: drop-count observability — parity with the legacy
        // path's per-drop logging, in pure-mapper form.
        if inputs.count != segments.count {
            logger.notice(
                "whisperkit: dropped \(inputs.count - segments.count) blank/hallucinated segment(s)")
        }
        let language = pinnedLanguage
            ?? results.first.map(\.language)
            ?? "unknown"
        return TranscriptionResult(segments: segments, language: language)
    }

    /// Lazily load (and, on a fresh download, account for) the WhisperKit
    /// model. Deviation B: the load is wrapped in a memoized `Task` so two
    /// concurrent decodes await one in-flight load instead of double-loading
    /// the CoreML bundle; a failed load is not cached (the slot is cleared by
    /// the failing task's own awaiters).
    private func ensureLoaded() async throws -> WhisperKit {
        if let pipeTask {
            do { return try await pipeTask.value.pipe }
            catch {
                // Only the failed task's own awaiters may clear the slot — a
                // retry may already have stored a fresh task.
                if self.pipeTask == pipeTask { self.pipeTask = nil }
                throw error
            }
        }

        // Capture everything the load `Task` needs by value (the `model_*`
        // event must fire only on a fresh download; a failure must not cache).
        let configuration = self.configuration
        let events = self.events
        let logger = self.logger

        // Store the Task before awaiting so a concurrent decode awaits this
        // same in-flight load.
        let task = Task<Box, Error> {
            let variantDir = configuration.downloadBase
                .appendingPathComponent(
                    "models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(
                    configuration.model.variant, isDirectory: true)
            let existedBefore = FileManager.default.fileExists(atPath: variantDir.path)

            let config = WhisperKitConfig(model: configuration.model.variant)
            config.downloadBase = configuration.downloadBase
            config.tokenizerFolder = configuration.downloadBase
                .appendingPathComponent("tokenizers", isDirectory: true)
            // ANE for encoder + decoder — the macOS 14+ defaults, set
            // explicitly because "off the GPU" is this whole plan's reason
            // to exist.
            config.computeOptions = ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine)
            // Prewarm: pay CoreML ANE specialization at load (sequential, low
            // peak memory) instead of inside the first region decode.
            config.prewarm = true
            config.load = true

            logger.notice(
                "whisperkit: loading \(configuration.model.variant) (cached=\(existedBefore))")
            let loaded = try await WhisperKit(config)
            logger.notice("whisperkit: model resident")

            if !existedBefore, let events {
                // Best-effort: a digest or append failure must never fail the
                // load — but keep the failure visible (matches ParakeetEngine).
                do {
                    let digest = try DirectoryDigest.compute(at: variantDir)
                    _ = try await events.append(ModelDownloadedEvent(
                        modelName: configuration.model.name,
                        sizeBytes: digest.totalBytes,
                        sha256: digest.sha256,
                        sourceHost: "huggingface.co"))
                } catch {
                    logger.warning("whisperkit: model_downloaded not emitted: \(error)")
                }
            }
            return Box(loaded)
        }
        pipeTask = task
        do { return try await task.value.pipe }
        catch {
            if self.pipeTask == task { self.pipeTask = nil }
            throw error
        }
    }

    /// The language to report on a degenerate (empty-result) decode. Resolve
    /// it through the same policy a real decode would use so a single-entry
    /// allow-list reports its pinned code rather than an inconsistent
    /// "unknown".
    private static func degenerateLanguage(_ options: TranscriptionOptions) -> String {
        if case .pin(let code) = WhisperKitLanguagePolicy.resolve(
            explicit: options.language, allowed: options.allowedLanguages) {
            return code
        }
        return "unknown"
    }

    /// Clamped sample index for a recording-relative offset — same math as
    /// the old `WhisperTranscriber.sampleIndex`.
    private static func sampleIndex(of offset: Duration, sampleCount: Int) -> Int {
        let index = Int(offset.seconds * Double(AudioFormat.sampleRate))
        return min(max(index, 0), sampleCount)
    }

    /// RMS energy floor below which a slice is treated as digital silence /
    /// dead air and never decoded. Deliberately conservative: real speech RMS
    /// is on the order of 1e-2…1e-1 and even quiet room tone is ~1e-3, so a
    /// floor of 1e-4 fires only on (near-)zero buffers — it cannot suppress a
    /// genuine utterance.
    private static let silenceRMSFloor: Float = 1e-4

    private static func isDigitalSilence(_ slice: [Float]) -> Bool {
        // Guard first: vDSP on an empty array is invalid.
        guard !slice.isEmpty else { return true }
        return vDSP.rootMeanSquare(slice) < silenceRMSFloor
    }
}
