> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 11: WhisperKitRegionTranscriber

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitRegionTranscriber.swift`
- Test: `Tests/PipelineTests/WhisperKitRefineTests.swift`

This task depends on types from earlier tasks — for reference while reading the code below: `WhisperKitModel`/`WhisperKitModelCatalog` (task 03: `name`, `variant`, `largeV3Turbo`), `DirectoryDigest.compute(at:)` (task 05), `WhisperKitSegmentMapper.InputSegment`/`segments(from:shiftedBy:dropHallucinations:)` (task 08), and `WhisperKitLanguagePolicy.resolve(explicit:allowed:) -> .pin/.detectAmong/.auto` (task 10).

- [ ] **Step 1: Write the failing integration test**

`Tests/PipelineTests/WhisperKitRefineTests.swift`:

```swift
import Foundation
import Logging
import Testing
@testable import PulsarTraceEngine

/// Integration coverage for the WhisperKit ANE refine backend. First run
/// downloads the ~626 MB large-v3-turbo bundle + tokenizer and pays CoreML
/// ANE specialization (can take minutes once per OS install) — later runs
/// are warm.
@Suite("WhisperKit refine backend", .serialized)
struct WhisperKitRefineTests {

    /// One lazily-loading transcriber per process: construction is cheap,
    /// the actor loads the model on first decode and serializes use.
    private static let transcriber = WhisperKitRegionTranscriber(
        configuration: .init(
            model: WhisperKitModelCatalog.largeV3Turbo,
            downloadBase: ModelStore.defaultCacheDirectory()
                .appendingPathComponent("whisperkit", isDirectory: true)),
        events: nil)

    private static func fixtureSamples(_ name: String) throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio/\(name)")
        return try WAVReader(contentsOf: url).samples
    }

    @Test func decodesARegionWithAbsoluteTimestamps() async throws {
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let region = SpeechRegion(start: .seconds(2), end: .seconds(12))
        let result = try await Self.transcriber.transcribe(
            samples, regions: [region], options: WhisperOptions())
        #expect(!result.segments.isEmpty)
        for seg in result.segments {
            #expect(seg.start >= .seconds(1))    // slack: whisper pads edges
            #expect(seg.end <= .seconds(13))
            #expect(!seg.text.isEmpty)
        }
    }

    @Test func languagePinningIsHonored() async throws {
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let region = SpeechRegion(start: .zero, end: .seconds(10))
        var options = WhisperOptions()
        options.language = "en"
        let result = try await Self.transcriber.transcribe(
            samples, regions: [region], options: options)
        #expect(result.language == "en")
        #expect(!result.segments.isEmpty)
    }

    @Test func detectAmongPinsTheBestAllowedLanguage() async throws {
        // Delta B rule 3: several allowed codes → detect on the region
        // slice, pin the argmax within the allowed set. English fixture +
        // ["en", "pl"] must resolve to "en" and decode non-empty.
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let region = SpeechRegion(start: .zero, end: .seconds(10))
        var options = WhisperOptions()
        options.allowedLanguages = ["en", "pl"]
        let result = try await Self.transcriber.transcribe(
            samples, regions: [region], options: options)
        #expect(result.language == "en")
        #expect(!result.segments.isEmpty)
    }

    @Test func emptyRegionListDecodesWholeBuffer() async throws {
        // The `regions: []` contract = whole-buffer fallback, mirroring
        // the old `WhisperTranscriber.transcribe(_:regions:options:)`.
        let samples = try Self.fixtureSamples("single-speaker-30s.wav")
        let result = try await Self.transcriber.transcribe(
            samples, regions: [], options: WhisperOptions())
        #expect(!result.segments.isEmpty)
    }

    @Test func silentRegionProducesNoStockPhraseLines() async throws {
        // The D31 regression shape: digital silence must not yield
        // "Thank you."-style hallucinations on the new backend.
        let silence = [Float](repeating: 0, count: AudioFormat.sampleRate * 8)
        let result = try await Self.transcriber.transcribe(
            silence, regions: [SpeechRegion(start: .zero, end: .seconds(8))],
            options: WhisperOptions())
        for seg in result.segments {
            #expect(!HallucinationFilter.stockPhrases.contains(
                HallucinationFilter.normalize(seg.text)))
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WhisperKitRefine` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: FAIL — type not found.

- [ ] **Step 3: Implement**

`Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitRegionTranscriber.swift`:

```swift
import Foundation
import Logging
import WhisperKit

/// The ANE refinement transcriber: Whisper large-v3-turbo (or full
/// large-v3) via WhisperKit, encoder + decoder on `.cpuAndNeuralEngine`.
/// Replaces the `pulsartrace-whisper` Metal subprocess on the refine path —
/// in-process, no flock, no Metal lock, GPU untouched.
///
/// An actor: WhisperKit's top-level class is not Sendable (v1.0.0 release
/// note) and keeps per-instance mutable state, so all access is serialized
/// here — matching the refine queue's single-worker invariant anyway.
///
/// Lazy load: construction is cheap and synchronous (so the queue's
/// `SharedTranscriberBox` can hold it); the model loads on the first decode.
/// Dropping the actor (the queue's pause-release hook) frees the CoreML
/// models via ARC — the in-process analogue of SIGTERMing the subprocess.
///
/// Wedge recovery: the old design SIGKILLed a wedged Metal decode. Here the
/// per-token `TranscriptionCallback` returns `false` once the deadline
/// passes, which makes WhisperKit stop decoding — no process to kill.
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

    private let configuration: Configuration
    private let events: EventWriter?
    private let logger: Logger
    private var pipe: WhisperKit?

    public init(
        configuration: Configuration,
        events: EventWriter?,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.configuration = configuration
        self.events = events
        self.logger = logger
    }

    // MARK: - Decode API (the refine seam)

    /// Decode one VAD region; segment timestamps come back recording-absolute
    /// — the same contract as the old `WhisperTranscriber.transcribeRegion`.
    public func transcribeRegion(
        _ samples: [Float],
        region: SpeechRegion,
        options: WhisperOptions
    ) async throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw WhisperTranscribeError.emptyAudio }
        let sampleCount = samples.count
        let lo = Self.sampleIndex(of: region.start, sampleCount: sampleCount)
        let hi = Self.sampleIndex(of: region.end, sampleCount: sampleCount)
        guard lo < hi else {
            return TranscriptionResult(
                segments: [], language: options.language ?? "unknown")
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
        options: WhisperOptions
    ) async throws -> TranscriptionResult {
        guard !samples.isEmpty else { throw WhisperTranscribeError.emptyAudio }
        guard !regions.isEmpty else {
            return try await decode(samples, shiftedBy: .zero, options: options)
        }
        var merged: [TranscriptSegment] = []
        var language: String?
        for region in regions {
            let result = try await transcribeRegion(
                samples, region: region, options: options)
            merged.append(contentsOf: result.segments)
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
        options: WhisperOptions
    ) async throws -> TranscriptionResult {
        let pipe = try await ensureLoaded()

        var decodeOptions = DecodingOptions()
        decodeOptions.task = .transcribe

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
            // Sources/WhisperKit/Core/WhisperKit.swift:533. Uses the first
            // 30 s of the slice internally; langProbs is keyed by ISO code.
            let (_, langProbs) = try await pipe.detectLangauge(audioArray: slice)
            let best = codes.max {
                (langProbs[$0] ?? 0) < (langProbs[$1] ?? 0)
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

        let budgetSeconds = max(
            configuration.decodeDeadline.seconds,
            Double(slice.count) / Double(AudioFormat.sampleRate))
        let deadline = Date().addingTimeInterval(budgetSeconds)
        let callback: TranscriptionCallback = { _ in
            Date() < deadline ? nil : false   // false = stop decoding
        }

        let results = try await pipe.transcribe(
            audioArray: slice, decodeOptions: decodeOptions, callback: callback)
        if Date() >= deadline {
            logger.error("whisperkit decode exceeded \(Int(budgetSeconds))s budget — treating as failed")
            throw WhisperTranscribeError.transcriptionFailed(-2)
        }

        let inputs = results.flatMap(\.segments).map {
            WhisperKitSegmentMapper.InputSegment(
                text: $0.text, start: $0.start, end: $0.end,
                noSpeechProb: $0.noSpeechProb, avgLogprob: $0.avgLogprob)
        }
        let segments = WhisperKitSegmentMapper.segments(
            from: inputs, shiftedBy: offset, dropHallucinations: true)
        let language = pinnedLanguage
            ?? results.first.map(\.language)
            ?? "unknown"
        return TranscriptionResult(segments: segments, language: language)
    }

    private func ensureLoaded() async throws -> WhisperKit {
        if let pipe { return pipe }

        let variantDir = configuration.downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(configuration.model.variant, isDirectory: true)
        let existedBefore = FileManager.default.fileExists(atPath: variantDir.path)

        let config = WhisperKitConfig(model: configuration.model.variant)
        config.downloadBase = configuration.downloadBase
        config.tokenizerFolder = configuration.downloadBase
            .appendingPathComponent("tokenizers", isDirectory: true)
        // ANE for encoder + decoder — the macOS 14+ defaults, set explicitly
        // because "off the GPU" is this whole plan's reason to exist.
        config.computeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine)
        // Prewarm: pay CoreML ANE specialization at load (sequential, low
        // peak memory) instead of inside the first region decode.
        config.prewarm = true
        config.load = true

        logger.notice("whisperkit: loading \(configuration.model.variant) (cached=\(existedBefore))")
        let loaded = try await WhisperKit(config)
        logger.notice("whisperkit: model resident")

        if !existedBefore, let events,
           let digest = try? DirectoryDigest.compute(at: variantDir) {
            _ = try? await events.append(ModelDownloadedEvent(
                modelName: configuration.model.name,
                sizeBytes: digest.totalBytes,
                sha256: digest.sha256,
                sourceHost: "huggingface.co"))
        }

        pipe = loaded
        return loaded
    }

    /// Clamped sample index for a recording-relative offset — same math as
    /// the old `WhisperTranscriber.sampleIndex`.
    private static func sampleIndex(of offset: Duration, sampleCount: Int) -> Int {
        let index = Int(offset.seconds * Double(AudioFormat.sampleRate))
        return min(max(index, 0), sampleCount)
    }
}
```

(`Duration.seconds` as a `Double` accessor already exists in this codebase — `ResumableRefiner` uses `seg.start.seconds * 1000`. If `WhisperKitConfig`'s stored properties differ from the assignments above, open the checkout at `.build/checkouts/argmax-oss-swift/Sources/WhisperKit/Core/Configurations.swift` — the property list was verified against v1.0.0, lines 7–73.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WhisperKitRefine`
Expected: PASS (5 tests). Budget several minutes on the very first run (download + ANE specialization).

- [ ] **Step 5: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitRegionTranscriber.swift Tests/PipelineTests/WhisperKitRefineTests.swift
git commit -m "feat(refine): WhisperKitRegionTranscriber — large-v3-turbo on the ANE with language policy"
```
