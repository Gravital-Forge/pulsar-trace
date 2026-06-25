# ANE Transcription Pipeline Implementation Plan — Overview

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move both transcription passes off the GPU and onto the Apple Neural Engine — live pass: Parakeet TDT 0.6B v3 via FluidAudio; refinement pass: Whisper large-v3-turbo via WhisperKit — and **remove whisper.cpp entirely** (CWhisper, the `pulsartrace-whisper` subprocess, WhisperIPC, the vendor build), so a recording never contends with Google Meet/screen-share for the GPU, while improving Polish/English accuracy and refinement speed.

**Architecture:** The swap happens entirely behind two existing seams: `WindowTranscribing` (live, one-method protocol) and the closure pair `ResumableRefiner.TranscribeRegion`/`DetectRegions` (refinement queue), plus a new closure struct for the CLI refine path. The live pass has exactly **one** backend (Parakeet v3) and **no model knob anywhere**; the refine pass has exactly **two** models, both WhisperKit/ANE (`large-v3-turbo` default, `large-v3-whisperkit` accuracy fallback). Language selection reuses the **existing** "Restrict to languages" selector across both passes (FluidAudio script hint on live; pin/detect-among on refine) plus a new explicit `refine --language` flag. Tasks 12–15 cut production over while the legacy sources still compile untouched; tasks 16–17 then delete whisper.cpp and rename the surviving `Whisper*`-named shared types. The repo compiles and stays green after every task.

**Tech Stack:** Swift 6 / SwiftPM, FluidAudio `v0.15.2` (Apache-2.0; Parakeet model CC-BY-4.0), argmax-oss-swift `v1.0.0` (WhisperKit, MIT; Whisper weights MIT), CoreML `.cpuAndNeuralEngine` compute units.

---

## How to execute this plan

Tasks live in this directory as `01-…` through `19-…`, one file per task. **Read this overview first; execute tasks in numeric order.** Each task file is self-contained (it repeats the type definitions and code it needs), starts from a green build, and ends with a commit and a green narrow-filter test run.

**Build/test mechanics (critical, easy to get wrong):** see `CLAUDE.md` at the repo root. `swift build` / `swift test` must run **bare** — no pipes, no redirects, no `&&` — and (when run from the Claude Code harness) with `dangerouslyDisableSandbox: true`. The broad `--filter PipelineTests` is known-flaky under cross-suite races; verify with the narrow filters named in each task. **No failing tests, ever** — every test passes or is explicitly gated.

## Scope decisions (read before starting)

1. **Diarization stays on Python/pyannote (MPS) in this plan.** Spec item 3 ("consider ANE for diarization") is **deliberately deferred to a separate follow-up plan**: FluidAudio's `OfflineDiarizerManager` runs the same pyannote community-1 pipeline on CoreML and the swap seams exist (`Diarizer`, the `LiveDiarizing` protocol), but the speaker library stores 256-d pyannote embeddings keyed by `pyannoteModelRevision` — switching embedding models requires a library migration/versioning design of its own. It is an independent subsystem; bundling it here would make neither plan independently shippable. Consequence for acceptance: during live recording, the windowed pyannote diarizer still puts a small periodic load on the GPU (a ~10 s window every ~5 s). This is far below the continuous ~90% GPU load of the old whisper Metal decode; the acceptance run measures it explicitly (task 19).
2. **whisper.cpp is fully removed by this plan** (tasks 16–17): CWhisper, the vendor build script, `pulsartrace-whisper`, WhisperIPC, `WhisperTranscriber`, `ModelCatalog`/`ModelStore`, and every `base`/`large-v3` ggml knob. There is no legacy fallback backend. The revert path if the ANE pipeline disappoints in dogfooding is `git revert` of this plan's commits; the *accuracy* fallback if `large-v3-turbo` hallucinates on real audio is the `large-v3-whisperkit` model — a Settings change, not a code change.
3. **Live language is auto-detect by default, with the FluidAudio script hint wired from the existing "Restrict to languages" selector.** When the selector holds **exactly one** code (e.g. `["pl"]`), the live pass passes the matching `FluidAudio.Language` as the script-aware `language:` hint to every batch decode (stops e.g. Cyrillic emissions on Polish audio). Zero or multiple codes → no hint (full auto). The pure mapping lives in `ParakeetEngine.languageHint(from:)` (task 06).
4. **Refine language reproduces the existing selector semantics on the new backend, plus an explicit override.** Per region decode: explicit `refine --language CODE` (new flag, task 14 — satisfies the spec's "language can be pre-selected on the post-processing pass") → hard pin; else exactly one allowed code → pin it; else multiple allowed codes → run WhisperKit language detection on the region slice and pin the highest-probability code **within** the allowed set; else full auto-detect. The pure decision lives in `WhisperKitLanguagePolicy` (task 10); the detection call lives in `WhisperKitRegionTranscriber` (task 11). `WhisperOptions.allowedLanguages` and the `--allowed-languages` flag / `RecordPlan` / `AppEnvironment` wiring all **survive unchanged**.
5. **No SHA-256 pinning for CoreML model bundles.** The old `ModelCatalog`/`ModelStore` pinned single ggml files; FluidAudio and WhisperKit manage multi-file CoreML bundles themselves. We point both SDKs at directories under `~/Library/Caches/PulsarTrace/models/` (keeping the "all model data under one root" rule, DECISIONS D10) and emit `model_downloaded` with a **computed directory digest** (deterministic SHA-256 over relative paths + per-file hashes) instead of a pinned hash. Upstream repos revise their CoreML bundles; pinning would turn every upstream fix into a hard failure. `RefinementJob.modelSHA256` and the `metadata.json` hash field stay (schema unchanged) with value `""` for these models. Recorded as DECISIONS D39 (task 18).

## Model name namespace (the contract every task builds against)

| Name (CLI/settings string) | Pass | Backend | What it loads |
|---|---|---|---|
| `parakeet-v3` | live — **fixed, not user-selectable** | FluidAudio | `FluidInference/parakeet-tdt-0.6b-v3-coreml`, int8 encoder, ~0.5 GB |
| `large-v3-turbo` | refine (default) | WhisperKit | `openai_whisper-large-v3-v20240930_626MB` (mixed-bit palettized large-v3-turbo) |
| `large-v3-whisperkit` | refine (accuracy fallback) | WhisperKit | `openai_whisper-large-v3_947MB` (quantized full large-v3, still ANE) |

There is **no live model knob**: no engine `--model` flag, no `record --model`/`--live-model`, no `MenuBarSettings.liveModelName`, no live picker. `parakeet-v3` appears only as the fixed value of the `recording_started` event's `model_live` field (public events schema — the field survives) and in `ParakeetEngine.modelName`. The refine knob is `WhisperKitModelCatalog` (task 03): exactly the two rows above, `defaultModel == largeV3Turbo`.

## Context for the implementing engineer

**Current live pass** (all paths relative to repo root):

- `Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift` accumulates 20 ms / 320-sample frames (16 kHz mono Float32), and every 4 s decodes a ≤10 s window anchored at the last committed position via the protocol below, then feeds the hypothesis to a LocalAgreement-2 committer (`LiveAgreementCommitter`). Windows must decode **deterministically** (argmax) — two consecutive windows must transcribe their shared audio identically or nothing ever commits.
- The seam (`Sources/PulsarTraceEngine/Transcription/WindowTranscribing.swift:11`):

```swift
public protocol WindowTranscribing: AnyObject {
    func transcribeWindow(
        _ samples: [Float],
        windowStart: Duration,
        options: WhisperOptions,
        abort: AbortToken?
    ) throws -> TranscriptionResult
}
```

- Input: window slice of mono 16 kHz Float32. Output: `TranscriptionResult { segments: [TranscriptSegment], language: String }` with **recording-absolute** timestamps (window-relative times shifted by `windowStart`). The method is synchronous and is called from a GCD global-queue offload (`LiveRunner`), so blocking inside it is by design.
- Production conformer today: `RemoteWindowTranscriber` → `pulsartrace-whisper` subprocess (whisper.cpp Metal). Constructed in `Sources/pulsartrace-engine/main.swift` (`live()`, lines ~181–256). Task 12 replaces that whole block.
- `LiveAgreementCommitter.tokens(from:start:end:)` splits each segment's text on whitespace and distributes the segment's span evenly across words. **Therefore: emitting one `TranscriptSegment` per word with Parakeet's real per-token times gives the committer exact word timing for free** — that is the mapper design in task 04.

**Current refinement pass:**

- Queue path (menubar, production): `RefinementJobQueue.makeStandard` (`Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:407`) wires `ResumableRefiner` with three closures — `TranscribeRegion` (already `async`), `DetectRegions` (currently sync — task 13 makes it async), `Diarize`. Per-region checkpointing to `refine-progress.json`; a `PauseGate` pauses refinement while recording; a release hook frees the transcriber on pause.
- CLI path: `pulsartrace refine` → `OfflineRefiner.refine` → `RefinementPipeline.run(transcriberFactory: () throws -> WhisperTranscriber, …)` — hard-typed to whisper.cpp today; task 14 re-seams it onto a backend-agnostic closure struct.
- VAD: speech regions come from whisper.cpp's bundled Silero VAD (`WhisperTranscriber.detectSpeechRegions`), coalesced with an 800 ms gap-merge (`WhisperTranscriber.coalesceRegions`, internal static, unit-tested in `Tests/UnitTests/SpeechRegionTests.swift`). Task 02 moves the coalescer to `SpeechRegion.coalesced(_:minGap:)` so it survives `WhisperTranscriber.swift`'s deletion; the new path uses FluidAudio's Silero-CoreML VAD (task 09) and **reuses the same coalescer**.
- Hallucination control on the offline path (DECISIONS D31): a segment is dropped only when its normalized text matches `HallucinationFilter.stockPhrases` **and** (`no_speech_prob ≥ 0.30` or `avgLogProb ≤ -0.80`). WhisperKit exposes both signals per segment (`noSpeechProb`, `avgLogprob`) — task 08 ports the gate.
- `WhisperOptions` (`Sources/PulsarTraceEngine/Transcription/WhisperOptions.swift`) is the option carrier through every seam: `language: String?` (nil = auto), `allowedLanguages: [String]`, `noSpeechThreshold: Float = 0.6`, plus whisper.cpp-only fields (`threadCount`, `temperature`, `temperatureFallbackStep`, `vadModelURL`) that task 17 deletes when renaming the type to `TranscriptionOptions`. Adapters map from it; do not fork it.
- `ModelStore.defaultCacheDirectory()` (`Sources/PulsarTraceEngine/Transcription/ModelStore.swift:88`) is **already `public`** and returns `~/Library/Caches/PulsarTrace/models/`. Tasks 06–15 use it as the cache root; task 16 replaces it with a new `AppPaths.modelsCacheDirectory` before deleting `ModelStore`.

**SDK facts (verified against pinned upstream sources, 2026-06-12):**

*FluidAudio v0.15.2* (`https://github.com/FluidInference/FluidAudio.git`, product `FluidAudio`, macOS 14+, zero transitive deps):

- The README/`Documentation/API.md` samples are **stale**. The real batch API (verified `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/`): `AsrModels.downloadAndLoad(to:version:…) -> AsrModels` (`AsrModels.swift:577`); `AsrModels.modelsExist(at:)` (`:600`); `AsrManager` is an **actor** — `init(config: ASRConfig = .default)`, `loadModels(_:)`, `public var decoderLayerCount: Int` (`AsrManager.swift:24`), and the batch decode (verified `AsrManager+Transcription.swift:5`):

```swift
public func transcribe(
    _ audioSamples: [Float], decoderState: inout TdtDecoderState, language: Language? = nil
) async throws -> ASRResult
```

- The `language:` **script hint** (added v0.14.1): "Optional language hint for script-aware token filtering (v3 only). When set, top-K tokens that don't match the language's script are skipped in favor of matching candidates." The enum (verified `Sources/FluidAudio/Shared/TokenLanguageFilter.swift:4`) is `public enum Language: String, Sendable, CaseIterable` with 28 cases, all ISO-639-1 raw values — Latin script: `.english = "en"`, `.spanish = "es"`, `.french = "fr"`, `.german = "de"`, `.italian = "it"`, `.portuguese = "pt"`, `.romanian = "ro"`, `.dutch = "nl"`, `.danish = "da"`, `.swedish = "sv"`, `.finnish = "fi"`, `.hungarian = "hu"`, `.estonian = "et"`, `.latvian = "lv"`, `.lithuanian = "lt"`, `.maltese = "mt"`, `.polish = "pl"`, `.czech = "cs"`, `.slovak = "sk"`, `.slovenian = "sl"`, `.croatian = "hr"`, `.bosnian = "bs"`; Cyrillic: `.russian = "ru"`, `.ukrainian = "uk"`, `.belarusian = "be"`, `.bulgarian = "bg"`, `.serbian = "sr"`; Greek: `.greek = "el"`. `FluidAudio.Language(rawValue: "pl")` therefore resolves any of those codes and returns `nil` for anything else (e.g. `"ja"`) — which is exactly the "unknown code → nil hint → auto" behaviour task 06 wants.
- Decoder state: `TdtDecoderState.make(decoderLayers:)` (`…/TDT/Decoder/TdtDecoderState.swift`).
- Default compute units are already `.cpuAndNeuralEngine` (preprocessor pinned `.cpuOnly` — it is CPU-bound by design). Nothing to configure for ANE.
- **Directory layout trap:** `AsrModels.download(to: dir)` treats `dir` as the model directory but internally re-derives it as `dir.deletingLastPathComponent() + "<repo folder name>"` (verified `AsrModels.swift:152-153`, `repoPath(from:)`). The directory you pass MUST therefore be named exactly `parakeet-tdt-0.6b-v3-coreml` (the HF repo folder name) or files land in a sibling directory.
- Input: 16 kHz mono `[Float]`, **minimum 300 ms** (shorter throws `ASRError.invalidAudioData`). ≤15 s fits one encoder window (our live windows are ≤10 s — never chunked, so the known long-form seam-merge bugs #683/#594 don't apply).
- Output: `ASRResult { text, confidence, duration, tokenTimings: [TokenTiming]?, … }`; `TokenTiming { token: String, tokenId: Int, startTime: TimeInterval, endTime: TimeInterval, confidence: Float }`. SentencePiece pieces — `"▁"` (U+2581) prefix marks a word start. No language field; greedy TDT decode is deterministic (LocalAgreement-2 safe).
- VAD: `VadManager` actor (Silero CoreML, repo `FluidInference/silero-vad-coreml`, `.cpuAndNeuralEngine` default): `init(config: VadConfig = .default) async throws` (auto-downloads), `segmentSpeech(_ samples: [Float], config: VadSegmentationConfig = .default) async throws -> [VadSegment]`; `VadSegment { startTime: TimeInterval, endTime: TimeInterval }` (seconds; verified v0.15.2 `Sources/FluidAudio/VAD/VadTypes.swift:137`).
- First-ever model load triggers CoreML ANE compilation (seconds; cached afterwards under the OS compile cache).

*argmax-oss-swift v1.0.0* (`https://github.com/argmaxinc/argmax-oss-swift.git` — **WhisperKit was renamed/merged into this repo at v1.0.0**, old URL redirects; product `WhisperKit`, module `import WhisperKit`, macOS 13+ manifest / 14+ effective, Swift 5.10 mode):

- `WhisperKitConfig` is an open **class** with all-`var` properties — construct minimal and assign properties (avoids init-argument-order churn): `model`, `downloadBase: URL?`, `modelFolder: String?`, `tokenizerFolder: URL?`, `computeOptions: ModelComputeOptions?`, `prewarm: Bool?`, `load: Bool?`, `download: Bool`.
- `ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)` — these are already the defaults on macOS 14+; set them explicitly anyway (self-documenting, and the mel stage stays `.cpuAndGPU` by design — it is trivial work).
- `transcribe(audioArray: [Float], decodeOptions: DecodingOptions?, callback: TranscriptionCallback?) async throws -> [TranscriptionResult]` (v1.0.0 removed the old optional-returning overloads). `TranscriptionCallback = @Sendable (TranscriptionProgress) -> Bool?` — fires per decoded token; **return `false` to cancel the decode** (this is the deadline mechanism, replacing the subprocess-SIGKILL design).
- Language pinning: `DecodingOptions.language = "pl"` + `usePrefillPrompt: true` (default) + `detectLanguage = false` force-feeds the `<|pl|>` token. `"pl"`/`"en"` are in `Constants.languages`.
- **Language detection** (verified `Sources/WhisperKit/Core/WhisperKit.swift:521` and `:533`) — note the second method name carries an **upstream typo** (`Langauge`), call it exactly as spelled:

```swift
open func detectLanguage(
    audioPath: String
) async throws -> (language: String, langProbs: [String: Float])

open func detectLangauge(    // [sic] — upstream typo in WhisperKit v1.0.0
    audioArray: [Float]
) async throws -> (language: String, langProbs: [String: Float])
```

  The `audioArray:` overload exists, so the detect-among path needs **no temp-WAV round trip**. It uses only the first 30 s internally (pads/trims to one mel window) and loads the models if needed. `langProbs` is keyed by ISO-639-1 code (built from `Constants.languages` values).
- `Constants.languages` (verified `Sources/WhisperKit/Core/Models.swift:1327-1335`) is **public**: `@frozen public enum Constants { public static let languages: [String: String] }` — display name → ISO code (`"english": "en"`, `"polish": "pl"`, … 99 entries); `public static let languageCodes: Set<String> = Set(languages.values)` (`:1451`). Task 16's `LanguageCatalog` is built from it.
- Models repo `argmaxinc/whisperkit-coreml`; with a custom `downloadBase`, a variant lands at `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>/`. The tokenizer is fetched separately (set `tokenizerFolder` so it caches under our root too).
- `prewarm: true` triggers CoreML ANE specialization at load (first time: possibly minutes; the OS evicts this cache on macOS updates — expect occasional slow first refines, surfaced via the existing queue stage UI).
- `TranscriptionSegment { text, start: Float, end: Float, tokens, avgLogprob, noSpeechProb, compressionRatio, … }` — times in seconds relative to the audio passed in.

**Name collisions to be aware of:** WhisperKit also defines `TranscriptionResult`; FluidAudio also defines `DiarizationResult`, `AudioConverter`, and a top-level `Language`. Inside `PulsarTraceEngine` sources the local types shadow the imported ones — qualify the *imported* ones explicitly when needed (`WhisperKit.TranscriptionResult`, `FluidAudio.Language`).

## File structure

**Create:**

| File | Task | Responsibility |
|---|---|---|
| `Sources/PulsarTraceEngine/Transcription/TranscriptTypes.swift` | 02 | `TranscriptSegment`, `TranscriptionResult`, `SpeechRegion` + `SpeechRegion.coalesced` (moved out of WhisperTranscriber.swift so they survive its deletion) |
| `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitModelCatalog.swift` | 03 | The two refine models: `WhisperKitModel` + `WhisperKitModelCatalog` (`defaultModel == largeV3Turbo`) |
| `Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetTokenMapper.swift` | 04 | Pure: Parakeet token timings → per-word `TranscriptSegment`s (recording-absolute) |
| `Sources/PulsarTraceEngine/Transcription/DirectoryDigest.swift` | 05 | Deterministic SHA-256 digest of a model directory tree (for `model_downloaded`) |
| `Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetEngine.swift` | 06 | Actor: model download/load into PulsarTrace cache, `model_downloaded` event, shared `AsrManager`, per-window decode with fresh decoder state, `languageHint(from:)` |
| `Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetWindowTranscriber.swift` | 07 | `WindowTranscribing` conformer: sync↔async bridge, 300 ms floor, 30 s watchdog, allowed-languages → script hint |
| `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitSegmentMapper.swift` | 08 | Pure: WhisperKit segments → filtered `TranscriptSegment`s (blank + D31 hallucination double-gate) |
| `Sources/PulsarTraceEngine/Transcription/FluidVADRegionDetector.swift` | 09 | Actor: FluidAudio Silero VAD → `[SpeechRegion]` + 800 ms coalescing |
| `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitLanguagePolicy.swift` | 10 | Pure: explicit/allowed-languages → `.pin` / `.detectAmong` / `.auto` |
| `Sources/PulsarTraceEngine/Transcription/WhisperKit/WhisperKitRegionTranscriber.swift` | 11 | Actor: lazy WhisperKit load (prewarm, our cache dir, event), region/whole decode, language policy, deadline cancel |
| `Tests/PipelineTests/ParakeetTestEngine.swift` | 12 | One memoized resident Parakeet engine per test process |
| `Sources/PulsarTraceEngine/Refinement/RefinementTranscriber.swift` | 14 | Closure struct for the CLI refine path + `.whisperKit` factory |
| `Sources/PulsarTraceEngine/Transcription/LanguageCatalog.swift` | 16 | `WhisperLanguageCatalog` replacement, built from `WhisperKit.Constants.languages` |
| Unit tests: `WhisperKitModelCatalogTests`, `ParakeetTokenMapperTests`, `DirectoryDigestTests`, `ParakeetLanguageHintTests`, `WhisperKitSegmentMapperTests`, `WhisperKitLanguagePolicyTests`, `LanguageCatalogTests` | 03–16 | Pure logic, no models |
| Integration tests: `Tests/PipelineTests/ParakeetTranscriberTests.swift`, `WhisperKitRefineTests.swift`, `FluidVADTests.swift` | 06–11 | Real model download + decode on committed fixtures |

**Modify (production):** `Package.swift` (01, 16), `Sources/pulsartrace-engine/main.swift` (12, 16), `Sources/PulsarTraceEngine/Refinement/RecordPlan.swift` (12), `Sources/pulsartrace/RecordCommand.swift` (12, 13, 14), `Sources/PulsarTraceMenuBar/RecordingViewModel.swift` (12, 13, 16), `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift` (13, 17), `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift` (13, 17), `Sources/PulsarTraceMenuBar/AppEnvironment.swift` (13, 16, 17), `Sources/PulsarTraceMenuBar/RefinementQueueHandle.swift` + `RefinementJobQueueViewModel.swift` (13), `Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift` (14, 17), `Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift` (14, 16), `Sources/pulsartrace/RefineCommand.swift` (14, 16, 17), `Sources/PulsarTraceMenuBar/MenuBarSettings.swift` + `Sources/pulsartrace-mac/SettingsView.swift` (15, 16), `Sources/PulsarTraceEngine/Support/AppPaths.swift` (16), `Sources/PulsarTraceEngine/Transcription/WindowTranscribing.swift` + `Streaming/StreamingTranscriber.swift` (17), `project-docs/DECISIONS.md` + `docs/release-smoke-test.md` + `docs/events-schema.md` + `CLAUDE.md` (18).

**Delete (task 16 unless noted):** `Sources/PulsarTraceEngine/WhisperIPC/` (all 11 files), `Sources/pulsartrace-whisper/`, `Sources/CWhisper/`, `Sources/PulsarTraceEngine/Transcription/{WhisperTranscriber,ModelCatalog,ModelStore,WhisperLanguageCatalog,RegionTranscribing}.swift`, `scripts/build-whisper.sh`, `Tests/UnitTests/WhisperIPC/` (all 11 files), `Tests/UnitTests/{WhisperLanguageAllowListTests,WhisperRegionTests,ModelStoreTests}.swift`, `Tests/PipelineTests/{WhisperAbortTests,WhisperSubprocessAcceptanceTests,TranscriptionPipelineTests,WhisperTestGate}.swift`; task 17: `Sources/PulsarTraceEngine/Transcription/AbortToken.swift`, `Tests/UnitTests/AbortTokenTests.swift`; task 12/14: the two retired snapshot files. **Keep** `SHA256Verifier.swift` — verified consumers beyond `ModelStore`: `AtomicFile.swift:76` and `SpeakerLibrary.swift:194`.

## Task index

Execute in order. "Depends on" lists hard prerequisites (a task always also assumes every lower-numbered task is done).

| # | File | Summary | Depends on |
|---|---|---|---|
| 01 | `01-spm-dependencies.md` | Add FluidAudio 0.15.2 + argmax-oss-swift 1.0.0 to Package.swift | — |
| 02 | `02-relocate-transcript-types.md` | Move `TranscriptSegment`/`TranscriptionResult`/`SpeechRegion` + coalescer into `TranscriptTypes.swift` | — (before 09 and 16) |
| 03 | `03-whisperkit-model-catalog.md` | `WhisperKitModel` + `WhisperKitModelCatalog` (the refine model namespace) | — |
| 04 | `04-parakeet-token-mapper.md` | Pure SentencePiece-timings → per-word segments mapper | — |
| 05 | `05-directory-digest.md` | Deterministic directory tree digest for `model_downloaded` | — |
| 06 | `06-parakeet-engine.md` | Resident Parakeet engine actor + language hint | 01, 04, 05 |
| 07 | `07-parakeet-window-transcriber.md` | `WindowTranscribing` conformer over the engine | 06 |
| 08 | `08-whisperkit-segment-mapper.md` | Pure WhisperKit segment mapper + D31 gate | — |
| 09 | `09-fluid-vad-region-detector.md` | FluidAudio Silero VAD → coalesced `SpeechRegion`s | 01, 02 |
| 10 | `10-whisperkit-language-policy.md` | Pure pin/detect-among/auto language resolution | — |
| 11 | `11-whisperkit-region-transcriber.md` | WhisperKit ANE region transcriber with language policy + deadline | 01, 03, 05, 08, 10 |
| 12 | `12-live-cutover.md` | Live pass → Parakeet only; kill the live model knob; migrate streaming tests | 01–07 |
| 13 | `13-refine-queue-cutover.md` | Queue → WhisperKit/FluidVAD only; drop the whisper binary threading | 01–11, 12 |
| 14 | `14-refine-cli-cutover.md` | CLI refine → WhisperKit; `--language`; `record --refine-model`; migrate refinement tests | 01–11, 13 |
| 15 | `15-menubar-settings.md` | Remove live-model setting/picker; WhisperKit refine picker; captions | 03, 12, 13 |
| 16 | `16-whisper-source-removal.md` | Delete whisper.cpp sources/tests; `AppPaths.modelsCacheDirectory`; `LanguageCatalog`; simplify Package.swift | 12–15 |
| 17 | `17-rename-sweep.md` | `WhisperOptions`→`TranscriptionOptions`, `WhisperTranscribeError`→`TranscriptionError`, drop `AbortToken` | 16 |
| 18 | `18-docs-and-decisions.md` | D39, smoke-test checklist, events-schema note, CLAUDE.md filter list | 16, 17 |
| 19 | `19-verification-acceptance.md` | Full filter sweep, menubar dogfood, D39 acceptance run, branch wrap-up | all |

## Follow-ups deliberately out of scope (do not start them inside this plan)

1. **Diarization on the ANE** — FluidAudio `OfflineDiarizerManager` (same pyannote community-1 pipeline, CoreML) behind `Diarizer`/`LiveDiarizing`; requires speaker-library embedding-space versioning/migration; removes the last GPU user and the Python layer.
2. **A non-reentrant cross-suite async mutex for `--filter PipelineTests`** — the broad-filter flakiness predates this plan (see `CLAUDE.md`); the narrow filters remain the verification mechanism.
3. **Per-job refine language override in the queue UI** — the queue inherits `allowedLanguages` (and the policy) from Settings at bootstrap; an explicit per-recording language picker in the menubar is a separate UX feature. The CLI `refine --language` covers the acceptance criterion.
