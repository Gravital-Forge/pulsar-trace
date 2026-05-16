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
/// Determinism (the project's test-discipline rule): greedy sampling,
/// `temperature = 0`, `temperature_inc = 0` (no fallback re-rolls), single
/// thread by default. With a pinned model hash this yields byte-identical
/// output across runs.
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
/// that the offline path doesn't need anyway. See DECISIONS.md D8.
///
/// GPU backend: `useGPU` defaults to `true` (production — Metal). The test/CI
/// path passes `useGPU: false` to use whisper's CPU backend, which avoids the
/// ggml-metal device entirely and so cannot trip the upstream
/// `ggml_metal_device_free` residency-set assertion that fires at process exit
/// when many `whisper_context`s are created/freed in one process. See
/// DECISIONS.md D15.
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

    /// Tunables for a transcription run. Defaults are the deterministic test
    /// configuration; production may raise `threadCount`.
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

        public init(
            language: String? = nil,
            threadCount: Int = 1,
            noSpeechThreshold: Float = 0.6
        ) {
            self.language = language
            self.threadCount = threadCount
            self.noSpeechThreshold = noSpeechThreshold
        }
    }

    private let ctx: OpaquePointer
    private let modelURL: URL
    private let logger: Logger
    /// True when the model file name marks an English-only model (`*.en`).
    private let isEnglishOnlyModel: Bool

    /// Load a ggml whisper model file and keep it resident.
    ///
    /// - Parameters:
    ///   - modelURL: a `ggml-*.bin` file (`base`, `large-v3`, …).
    ///   - useGPU: `true` (default) loads the model on the Metal backend — the
    ///     production path. `false` uses whisper's CPU backend; the test/CI
    ///     suite passes `false` so it never touches the ggml-metal device and
    ///     so cannot trip the upstream exit-time residency-set assertion
    ///     (DECISIONS.md D15).
    public init(
        modelURL: URL,
        useGPU: Bool = true,
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
        // CPU backend for tests/CI (DECISIONS.md D15).
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
    /// (`AudioFormat`). This is a single `whisper_full` call (offline path).
    ///
    /// - Important: this is a blocking, CPU/GPU-bound call that runs for seconds
    ///   (longer for `large-v3` or long recordings) and holds a process-wide
    ///   lock. It must never be called from the main actor — dispatch it to a
    ///   background task/queue.
    public func transcribe(_ samples: [Float], options: Options = Options()) throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw TranscribeError.emptyAudio }

        // Epic 2 edge case: an `*.en` model on (possibly) non-English audio.
        // We default to multilingual so this is just a logged warning path.
        if isEnglishOnlyModel {
            logger.warning(
                "english-only whisper model in use; non-English speech will be mis-transcribed")
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threadCount)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.no_context = true            // offline: each run is independent
        // Determinism: temperature 0, no fallback re-rolls.
        params.temperature = 0
        params.temperature_inc = 0
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

        // Serialize the whole ctx-touching region: `whisper_full` plus the
        // segment/language reads run under the Metal lock (DECISIONS.md D8).
        // `defer` guarantees the lock is released even on an unexpected throw.
        Self.metalLock.lock()
        defer { Self.metalLock.unlock() }

        let code: Int32 = langString.withCString { langPtr -> Int32 in
            params.language = langPtr
            params.detect_language = false   // whisper_full auto-detects on "auto"
            return runFull(&params, samples)
        }
        guard code == 0 else {
            throw TranscribeError.transcriptionFailed(Int(code))
        }

        let detectedLangId = whisper_full_lang_id(ctx)
        let language = detectedLangId >= 0
            ? String(cString: whisper_lang_str(detectedLangId))
            : (isEnglishOnlyModel ? "en" : "unknown")

        let segments = collectSegments()

        let segmentCount = segments.count
        logger.notice(
            "transcription complete; language=\(language), segments=\(segmentCount)")
        return TranscriptionResult(segments: segments, language: language)
    }

    // MARK: - Private

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
