> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 06: ParakeetEngine — model load + shared decode actor + language hint

**Files:**
- Create: `Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetEngine.swift`
- Test: `Tests/UnitTests/ParakeetLanguageHintTests.swift` (pure, no model)
- Test: `Tests/PipelineTests/ParakeetTranscriberTests.swift` (engine load + decode; task 07 appends to it)

Notes before starting:
- `ModelStore.defaultCacheDirectory()` (`Sources/PulsarTraceEngine/Transcription/ModelStore.swift:88`) is **already `public`** (verified) and returns `~/Library/Caches/PulsarTrace/models/` — no change needed. Task 16 swaps every call site to `AppPaths.modelsCacheDirectory` before deleting `ModelStore`.
- **Model-directory trap:** the cache directory's last path component MUST be exactly `parakeet-tdt-0.6b-v3-coreml`, because `AsrModels.download(to:)` re-derives the repo path as `directory.deletingLastPathComponent() + <repo folder name>` (verified v0.15.2 `AsrModels.swift:152-153`).
- The fixture is verified present: `Tests/Fixtures/audio/single-speaker-30s.wav`.

- [ ] **Step 1: Write the failing language-hint unit tests**

`Tests/UnitTests/ParakeetLanguageHintTests.swift`:

```swift
import Testing
@testable import PulsarTraceEngine

/// The pure "Restrict to languages" → FluidAudio script-hint mapping
/// (plan scope decision 3): exactly one allowed code becomes the hint;
/// zero or several codes mean auto (no hint).
@Suite("Parakeet language hint")
struct ParakeetLanguageHintTests {

    @Test func singleAllowedCodeBecomesTheHint() {
        #expect(ParakeetEngine.languageHint(from: ["pl"]) == "pl")
        #expect(ParakeetEngine.languageHint(from: ["EN"]) == "en")  // normalized
    }

    @Test func emptyListMeansAuto() {
        #expect(ParakeetEngine.languageHint(from: []) == nil)
    }

    @Test func multipleCodesMeanAuto() {
        // With several allowed languages the live pass cannot pick one —
        // scripts may differ per speaker; auto-detect handles it.
        #expect(ParakeetEngine.languageHint(from: ["en", "pl"]) == nil)
    }
}
```

- [ ] **Step 2: Write the failing integration test**

`Tests/PipelineTests/ParakeetTranscriberTests.swift`:

```swift
import Foundation
import Logging
import Testing
@testable import PulsarTraceEngine

/// Integration coverage for the Parakeet live backend. Downloads the
/// ~0.5 GB CoreML bundle into the standard PulsarTrace model cache on first
/// run (network: huggingface.co — the permitted model-download call), then
/// reuses it. Serialized: one ANE model load at a time keeps memory sane.
@Suite("Parakeet live backend", .serialized)
struct ParakeetTranscriberTests {

    /// One engine per process — memoized Task, same race-free pattern as
    /// WhisperTestGate.model (a second caller awaits the in-flight load
    /// instead of starting a second download).
    private static let engineTask = Task<ParakeetEngine, Error> {
        try await ParakeetEngine.load(
            cacheRoot: ModelStore.defaultCacheDirectory(),
            events: nil,
            logger: Logger(label: "test.parakeet"))
    }

    private static func fixtureSamples(seconds: Int) throws -> [Float] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/PipelineTests
            .deletingLastPathComponent()    // Tests
            .appendingPathComponent("Fixtures/audio/single-speaker-30s.wav")
        let samples = try WAVReader(contentsOf: fixture).samples
        return Array(samples.prefix(AudioFormat.sampleRate * seconds))
    }

    @Test func loadsAndDecodesAFixtureWindow() async throws {
        let engine = try await Self.engineTask.value
        // 10 s window from the committed single-speaker fixture.
        let window = try Self.fixtureSamples(seconds: 10)
        let decoded = try await engine.transcribeWindow(window, languageHint: nil)
        #expect(!decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!decoded.tokens.isEmpty)
        // Timings are window-relative and inside the window.
        for token in decoded.tokens {
            #expect(token.start >= 0)
            #expect(token.end <= 10.5)
            #expect(token.end >= token.start)
        }
    }

    @Test func decodeIsDeterministicAcrossCalls() async throws {
        // LocalAgreement-2 requires two decodes of the same audio to agree.
        let engine = try await Self.engineTask.value
        let window = try Self.fixtureSamples(seconds: 8)
        let first = try await engine.transcribeWindow(window, languageHint: nil)
        let second = try await engine.transcribeWindow(window, languageHint: nil)
        #expect(first.text == second.text)
    }

    @Test func hintedDecodeStillTranscribes() async throws {
        // The script hint must steer, not break: an English hint on the
        // English fixture decodes non-empty text. (An unknown code would
        // map to nil internally — auto — and also decode fine.)
        let engine = try await Self.engineTask.value
        let window = try Self.fixtureSamples(seconds: 8)
        let decoded = try await engine.transcribeWindow(window, languageHint: "en")
        #expect(!decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter Parakeet` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md)
Expected: `ParakeetTokenMapper` unit tests PASS; the new suites FAIL — `cannot find 'ParakeetEngine' in scope`.

- [ ] **Step 4: Implement**

`Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetEngine.swift`:

```swift
import FluidAudio
import Foundation
import Logging

/// The resident Parakeet TDT 0.6B v3 model (live pass, R10) — loaded once
/// per process and shared by the system and mic stream transcribers. The
/// live pass has exactly one backend; there is no live model knob (D39).
///
/// FluidAudio's `AsrManager` is an actor, so concurrent window decodes from
/// the two streams serialize automatically (the in-process analogue of the
/// old whisper subprocess's `SerializingHostProxy`). Each window decodes
/// with a **fresh** `TdtDecoderState`: streaming windows overlap, and
/// reusing decoder state across them would let one window's tail condition
/// the next — the same reason the whisper path set `no_context = true`.
/// Compute units: FluidAudio's defaults are already `.cpuAndNeuralEngine`
/// (preprocessor `.cpuOnly` by design) — the GPU is never touched.
public actor ParakeetEngine {

    /// The model name recorded in events (`recording_started.model_live`).
    /// Not user-selectable.
    public static let modelName = "parakeet-v3"
    /// The Hugging Face repo folder name. The cache directory's last path
    /// component MUST be exactly this: `AsrModels.download(to:)` re-derives
    /// the model path as `directory.deletingLastPathComponent() +
    /// <repo folder name>` (verified v0.15.2 AsrModels.swift `repoPath`).
    public static let repoFolderName = "parakeet-tdt-0.6b-v3-coreml"

    /// One decoded window: the raw text plus per-token timings (window-
    /// relative seconds), pre-adapted to the mapper's input type.
    public struct WindowDecode: Sendable {
        public let text: String
        public let tokens: [ParakeetTokenMapper.InputToken]
    }

    private let manager: AsrManager
    private let decoderLayers: Int

    private init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager
        self.decoderLayers = decoderLayers
    }

    /// The "Restrict to languages" → script-hint rule (scope decision 3):
    /// exactly one allowed code → that code (normalized); zero or several →
    /// `nil` (auto). Pure, so it unit-tests without a model; the code →
    /// `FluidAudio.Language` mapping happens inside `transcribeWindow`.
    public static func languageHint(from allowedLanguages: [String]) -> String? {
        guard allowedLanguages.count == 1 else { return nil }
        return allowedLanguages[0].lowercased()
    }

    /// Download (first run only; ~0.5 GB from huggingface.co — the permitted
    /// model-download network call) and load the model from
    /// `<cacheRoot>/parakeet-tdt-0.6b-v3-coreml`, keeping every PulsarTrace
    /// model under one cache root (D10). Emits `model_downloaded` with a
    /// `DirectoryDigest` after a fresh download (D39).
    public static func load(
        cacheRoot: URL,
        events: EventWriter?,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) async throws -> ParakeetEngine {
        let modelDir = cacheRoot.appendingPathComponent(
            repoFolderName, isDirectory: true)
        let existedBefore = AsrModels.modelsExist(at: modelDir)

        logger.notice("parakeet: ensuring model available (cached=\(existedBefore))")
        let models = try await AsrModels.downloadAndLoad(to: modelDir, version: .v3)

        if !existedBefore, let events {
            // Best-effort: a digest failure must never fail a live session.
            if let digest = try? DirectoryDigest.compute(at: modelDir) {
                _ = try? await events.append(ModelDownloadedEvent(
                    modelName: modelName,
                    sizeBytes: digest.totalBytes,
                    sha256: digest.sha256,
                    sourceHost: "huggingface.co"))
            }
        }

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        logger.notice("parakeet: model resident (decoderLayers=\(layers))")
        return ParakeetEngine(manager: manager, decoderLayers: layers)
    }

    /// Decode one streaming window.
    ///
    /// `languageHint` is the resolved single allowed code (`languageHint(from:)`)
    /// or `nil` for auto. The code is mapped to FluidAudio's script-aware
    /// `Language` here; a code FluidAudio doesn't know (e.g. `"ja"` — the
    /// enum covers Latin/Cyrillic/Greek scripts only) maps to `nil`, i.e.
    /// auto — never an error.
    public func transcribeWindow(
        _ samples: [Float],
        languageHint: String? = nil
    ) async throws -> WindowDecode {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let language = languageHint.flatMap { FluidAudio.Language(rawValue: $0) }
        let result = try await manager.transcribe(
            samples, decoderState: &state, language: language)
        let tokens = (result.tokenTimings ?? []).map {
            ParakeetTokenMapper.InputToken(
                token: $0.token, start: $0.startTime, end: $0.endTime)
        }
        return WindowDecode(text: result.text, tokens: tokens)
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter ParakeetLanguageHint`
Expected: PASS (3 tests).
Run: `swift test --filter Parakeet`
Expected: PASS. First run downloads the bundle (minutes on a slow link) and pays one-time CoreML ANE compilation; later runs are warm. If the `decoderLayerCount`, `modelsExist(at:)`, or `TdtDecoderState.make(decoderLayers:)` symbols don't resolve, open the pinned checkout at `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/` and match the exact member names — the surface above was verified against the v0.15.2 tag, but this is the one SDK whose naming churns.

- [ ] **Step 6: Commit**

```bash
git add Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetEngine.swift Tests/UnitTests/ParakeetLanguageHintTests.swift Tests/PipelineTests/ParakeetTranscriberTests.swift
git commit -m "feat(live): ParakeetEngine — resident ANE Parakeet v3 with script-hint support"
```
