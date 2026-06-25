> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 14: Refine CLI cutover — RefinementTranscriber, `refine --language`, `record --refine-model`

The one-shot CLI path (`pulsartrace refine` → `OfflineRefiner` → `RefinementPipeline`) moves to WhisperKit. `RefinementPipeline.run` is re-seamed from `transcriberFactory: () throws -> WhisperTranscriber` onto a backend-agnostic closure struct with **only** a `.whisperKit` factory (there is no legacy backend). `refine` gains `--language` (the spec's "language can be pre-selected on the post-processing pass"); `record` gains `--refine-model`. Every test call site of `run(transcriberFactory:)` migrates here too — `RefinementPipelineTests` and `SpeakerLibraryPipelineTests` — because the signature change breaks them at compile time.

Types from earlier tasks used here: `WhisperKitModelCatalog` (task 03), `WhisperKitRegionTranscriber` (task 11: `transcribe(_:regions:options:)`, `Configuration(model:downloadBase:)`), `FluidVADRegionDetector` (task 09).

**Files:**
- Create: `Sources/PulsarTraceEngine/Refinement/RefinementTranscriber.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/RefinementPipeline.swift:174-185` (run signature), `:236-260` (private refine), `:426-476` (`transcribe` body)
- Modify: `Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift:42-101`
- Modify: `Sources/pulsartrace/RefineCommand.swift`
- Modify: `Sources/pulsartrace/RecordCommand.swift` (`--refine-model`)
- Modify: `Tests/PipelineTests/RefinementPipelineTests.swift`, `Tests/PipelineTests/SpeakerLibraryPipelineTests.swift`
- Delete: `Tests/PipelineTests/__Snapshots__/RefinementPipelineTests/bareWavEndToEnd.1.txt`

- [ ] **Step 1: Create the closure struct**

`Sources/PulsarTraceEngine/Refinement/RefinementTranscriber.swift`:

```swift
import Foundation

/// Backend-agnostic transcription seam for the one-shot CLI refine path
/// (`RefinementPipeline`), mirroring the closure shape `ResumableRefiner`
/// already uses on the queue path.
///
/// Contract:
/// - `detectRegions` returns the stream's speech regions; `[]` means "no
///   regions to slice by" and `transcribeRegions` then performs a
///   whole-buffer decode (WhisperKit's internal 30 s seek loop handles
///   arbitrary lengths). A throw is caught by the pipeline and treated
///   as `[]`.
/// - `transcribeRegions` returns recording-absolute segments.
public struct RefinementTranscriber: Sendable {
    public typealias DetectRegions =
        @Sendable ([Float]) async throws -> [SpeechRegion]
    public typealias TranscribeRegions =
        @Sendable ([Float], [SpeechRegion], WhisperOptions) async throws
        -> TranscriptionResult

    public let detectRegions: DetectRegions
    public let transcribeRegions: TranscribeRegions

    public init(
        detectRegions: @escaping DetectRegions,
        transcribeRegions: @escaping TranscribeRegions
    ) {
        self.detectRegions = detectRegions
        self.transcribeRegions = transcribeRegions
    }

    /// The production wiring: WhisperKit decode + FluidAudio VAD (D39).
    public static func whisperKit(
        _ transcriber: WhisperKitRegionTranscriber,
        vad: FluidVADRegionDetector
    ) -> RefinementTranscriber {
        RefinementTranscriber(
            detectRegions: { samples in
                try await vad.detectRegions(samples)
            },
            transcribeRegions: { samples, regions, options in
                try await transcriber.transcribe(
                    samples, regions: regions, options: options)
            })
    }
}
```

- [ ] **Step 2: Re-seam RefinementPipeline**

In `RefinementPipeline.swift`:

1. In the public `run(...)` (line ~174): replace the parameter `transcriberFactory: @Sendable () throws -> WhisperTranscriber` with `transcriber: RefinementTranscriber`, and replace its doc-comment entry (the "builds a model-resident `WhisperTranscriber`… one context per source" paragraph) with:

```swift
    ///   - transcriber: backend-agnostic transcription closures
    ///     (`RefinementTranscriber`) — region detection + region/whole
    ///     decode, shared by the mic and system streams (the WhisperKit
    ///     actor serializes).
```

2. Thread it through: the internal `run → refine(...)` call passes `transcriber: transcriber`; the private `refine(...)` (line ~236) and its forwarding to `transcribe(wav:...)` (line ~307) replace `transcriberFactory:` the same way.
3. Replace the body of the private `transcribe(wav:transcriberFactory:options:)` helper (lines ~426–476) — new signature `transcribe(wav: URL, transcriber: RefinementTranscriber, options: WhisperOptions)` — keeping the surrounding `do/catch` that wraps everything in `RefineError.transcription`:

```swift
        do {
            let source = FixturePlaybackSource(file: wav, realtime: false)
            let pipeline = OfflineTranscriptionPipeline(logger: logger)
            let samples = try await pipeline.accumulate(source)

            // No usable speech at all: hand back an empty transcript rather
            // than letting the backend throw `emptyAudio`. The pipeline then
            // writes a valid, explanatory `final.md` (edge case).
            guard !samples.isEmpty else {
                return StreamTranscription(
                    segments: [], language: "unknown", audioDuration: .zero)
            }
            let duration = Duration.milliseconds(
                samples.count * 1000 / AudioFormat.sampleRate)

            // Region-segmented decode (D26): regions from the backend's VAD;
            // a detection failure degrades to the backend's whole-buffer
            // decode (regions == []), never fails the refine.
            var regions: [SpeechRegion] = []
            do {
                regions = try await transcriber.detectRegions(samples)
            } catch {
                logger.warning("VAD region detection failed — whole-buffer decode")
            }
            let result = try await transcriber.transcribeRegions(
                samples, regions, options)
            return StreamTranscription(
                segments: result.segments,
                language: result.language,
                audioDuration: duration)
        } catch {
            throw RefineError.transcription(error)
        }
```

- [ ] **Step 3: Re-seam OfflineRefiner (WhisperKit-only, language parameter)**

In `OfflineRefiner.swift`, replace `refine(inputPath:model:progress:)` (lines ~42–101) with the following (the old whisper-model/VAD-model `ModelStore` fetches are gone — WhisperKit and FluidVAD manage their own bundles):

```swift
    /// Setup failures that precede the pipeline (so they are never confused
    /// with a `RefineError.input` path problem — verified:
    /// `RecordingFolder.InputError` only has path-shaped cases).
    public enum SetupError: Error, CustomStringConvertible, Equatable {
        case unknownModel(String)

        public var description: String {
            switch self {
            case .unknownModel(let name):
                return "unknown refine model '\(name)' (expected: "
                    + WhisperKitModelCatalog.all.map(\.name).joined(separator: ", ")
                    + ")"
            }
        }
    }

    /// Run the offline refine pass over one audio file or recording folder.
    ///
    /// - Parameters:
    ///   - inputPath: audio file or recording folder.
    ///   - modelName: a `WhisperKitModelCatalog` name
    ///     (`large-v3-turbo` | `large-v3-whisperkit`).
    ///   - language: ISO-639-1 code pinning the decode language
    ///     (`refine --language`), or `nil` → the allowed-languages policy /
    ///     auto-detect (`WhisperKitLanguagePolicy`).
    ///   - progress: optional human-readable progress callback.
    /// - Returns: the `RefinementPipeline.Output`.
    /// - Throws: `SetupError`, or `RefinementPipeline.RefineError` — callers
    ///   must propagate, never swallow.
    @discardableResult
    public func refine(
        inputPath: URL,
        modelName: String,
        language: String? = nil,
        progress: ProgressReporter? = nil
    ) async throws -> RefinementPipeline.Output {
        guard let model = WhisperKitModelCatalog.model(named: modelName) else {
            throw SetupError.unknownModel(modelName)
        }

        progress?("preparing \(model.name) (ANE)…")
        let whisperKit = WhisperKitRegionTranscriber(
            configuration: .init(
                model: model,
                downloadBase: ModelStore.defaultCacheDirectory()
                    .appendingPathComponent("whisperkit", isDirectory: true)),
            events: events)
        let transcriber: RefinementTranscriber = .whisperKit(
            whisperKit, vad: FluidVADRegionDetector())
        let whisperOptions = WhisperOptions(language: language)

        let diarizer = try Self.makeDiarizer()

        // The persistent speaker library at the standard location. A failure
        // to open it is non-fatal — refine continues with `Speaker_N` labels.
        let library = try? await SpeakerLibrary(
            databaseURL: paths.speakersDatabaseURL, events: events)
        if library == nil {
            progress?("speaker library unavailable — using Speaker_N labels")
        }

        let pipeline = RefinementPipeline(events: events)
        let stageProgress: RefinementPipeline.ProgressReporter = { stage in
            progress?("\(stage.rawValue)…")
        }

        return try await pipeline.run(
            inputPath: inputPath,
            transcriber: transcriber,
            diarizer: diarizer,
            whisperModelName: model.name,
            whisperModelSHA256: "",   // SDK-managed CoreML bundle (D39)
            recordingStart: Date(),
            whisperOptions: whisperOptions,
            library: library,
            progress: stageProgress)
    }
```

Also update the class doc comment's last paragraph ("…constructing the `WhisperTranscriber` factory") to say "…and constructing the WhisperKit transcriber + FluidVAD wiring".

- [ ] **Step 4: Rework RefineCommand**

In `Sources/pulsartrace/RefineCommand.swift`:

1. `Options` gains `let language: String?`.
2. `ArgError`: add `case unknownLanguage(String)` and `case missingLanguageValue`; update descriptions:

```swift
            case .unknownModel(let m):
                return "refine: unknown --model '\(m)' (expected: "
                    + WhisperKitModelCatalog.all.map(\.name).joined(separator: ", ") + ")"
            case .unknownLanguage(let c):
                return "refine: unknown --language '\(c)' (ISO-639-1, e.g. en, pl)"
            case .missingLanguageValue:
                return "refine: --language needs a value (ISO-639-1, e.g. en, pl)"
            case .missingModelValue:
                return "refine: --model needs a value ("
                    + WhisperKitModelCatalog.all.map(\.name).joined(separator: "|") + ")"
```

3. `parse`: default model becomes the catalog default, `--language`/`--language=` mirror the `--model` pattern, and validation moves to the new catalogs:

```swift
    static func parse(_ args: [String]) throws -> Options {
        var path: String?
        var model = WhisperKitModelCatalog.defaultModel.name
        var language: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--model":
                guard i + 1 < args.count else { throw ArgError.missingModelValue }
                model = args[i + 1]
                i += 2
            case let a where a.hasPrefix("--model="):
                model = String(a.dropFirst("--model=".count))
                i += 1
            case "--language":
                guard i + 1 < args.count else { throw ArgError.missingLanguageValue }
                language = args[i + 1]
                i += 2
            case let a where a.hasPrefix("--language="):
                language = String(a.dropFirst("--language=".count))
                i += 1
            case let a where a.hasPrefix("-"):
                throw ArgError.unexpectedArgument(a)
            default:
                if path == nil {
                    path = arg
                } else {
                    throw ArgError.unexpectedArgument(arg)
                }
                i += 1
            }
        }

        guard let path else { throw ArgError.missingPath }
        guard WhisperKitModelCatalog.model(named: model) != nil else {
            throw ArgError.unknownModel(model)
        }
        // Validated against the language catalog. NOTE: until task 17
        // replaces it, the catalog type is still the CWhisper-backed
        // `WhisperLanguageCatalog`; task 16/17 swap this line to
        // `LanguageCatalog.language(forCode:)` mechanically.
        if let language,
           WhisperLanguageCatalog.language(forCode: language) == nil {
            throw ArgError.unknownLanguage(language)
        }
        return Options(
            inputPath: URL(fileURLWithPath: path),
            modelName: model,
            language: language?.lowercased())
    }
```

4. In `run`: delete the `guard let model = ModelCatalog.model(named:)` block (lines ~54–57) and change the refiner call:

```swift
            let refiner = OfflineRefiner(events: events, paths: .standard)
            let output = try await refiner.refine(
                inputPath: options.inputPath,
                modelName: options.modelName,
                language: options.language,
                progress: { err("refine: \($0)") })
```

5. Update both usage strings (the doc comment at the top and the `err(usage)` string in `run`):

```
usage: pulsartrace refine PATH [--model large-v3-turbo|large-v3-whisperkit] [--language CODE]
```

- [ ] **Step 5: Add `--refine-model` to RecordCommand**

In `Sources/pulsartrace/RecordCommand.swift`:

1. `Options` gains `let refineModelName: String`.
2. `parse`: add `var refineModelName = WhisperKitModelCatalog.defaultModel.name` and a `case "--refine-model": refineModelName = try value("--refine-model")` arm; pass it through `Options(...)`.
3. Validation (where the old `--model` guard used to be, ~line 55):

```swift
        guard WhisperKitModelCatalog.model(named: options.refineModelName) != nil else {
            err("record: unknown --refine-model '\(options.refineModelName)' (expected: "
                + WhisperKitModelCatalog.all.map(\.name).joined(separator: ", ") + ")")
            return 2
        }
```

4. The post-record refine invocation (task 12 left it interim) becomes:

```swift
        let refineCode = await RefineCommand.run(
            [outputFolder.path, "--model", options.refineModelName], events: events)
```

5. Usage string:

```swift
    static let usage =
        "usage: pulsartrace record [--output PATH] [--duration MIN] "
        + "[--mic INDEX] [--no-system-audio] "
        + "[--refine-model large-v3-turbo|large-v3-whisperkit] [--list-mics]"
```

(Add `import PulsarTraceEngine` to neither file — both already import it.)

- [ ] **Step 6: Migrate RefinementPipelineTests**

`Tests/PipelineTests/RefinementPipelineTests.swift` has five `pipeline.run(... transcriberFactory: ...)` call sites. Migration recipe:

1. Drop `import SnapshotTesting` (the snapshot is retired below).
2. Add the shared transcriber maker to the suite (construction is cheap; the actor loads the model once on first decode and serializes use):

```swift
    /// One lazily-loading WhisperKit transcriber per process (D39 backend).
    private static let whisperKit = WhisperKitRegionTranscriber(
        configuration: .init(
            model: WhisperKitModelCatalog.largeV3Turbo,
            downloadBase: ModelStore.defaultCacheDirectory()
                .appendingPathComponent("whisperkit", isDirectory: true)),
        events: nil)

    private static func makeTranscriber() -> RefinementTranscriber {
        .whisperKit(whisperKit, vad: FluidVADRegionDetector())
    }
```

3. Delete the `baseModelURL()` helper. In **every** `pipeline.run` call: replace `transcriberFactory: { try WhisperTestTranscriber.make(modelURL: modelURL) }` (or `factory`) with `transcriber: Self.makeTranscriber()`, replace `whisperModelName: ModelCatalog.base.name` with `whisperModelName: "large-v3-turbo"`, replace `whisperModelSHA256: ModelCatalog.base.sha256` with `whisperModelSHA256: ""`, and unwrap the `WhisperTestGate.run { … }` wrappers (keep the body; the gate guarded whisper.cpp's single-context constraint, which WhisperKit doesn't have — `.serialized` plus the shared actor is enough). Delete the now-unused `let modelURL = …` and `let factory…` lines, and `reRefineBackupAndEvent`'s `factory` constant.
4. In `interleavedTurnsStayInCausalOrder`: also delete the `vadModelURL` fetch (`let vadModelURL = try await WhisperTestGate.model(ModelCatalog.sileroVAD)`) and the `whisperOptions: .init(vadModelURL: vadModelURL),` argument — regions now come from `FluidVADRegionDetector` inside the transcriber. Everything else (the fixture assembly, `precomputedDiarization`, the causal-order assertions) is unchanged.
5. In `bareWavEndToEnd`: keep every structural/metadata assertion but update the model expectation and replace the snapshot. Change `#expect(metadata.whisperModel.name == "base")` to `#expect(metadata.whisperModel.name == "large-v3-turbo")`. Replace the final two lines (`// Snapshot the final.md body…` + `assertSnapshot(...)`) with keyword assertions — the words come from the retired snapshot `__Snapshots__/RefinementPipelineTests/bareWavEndToEnd.1.txt` ("…coffee shop this morning… near the bookstore… the barista asked me… we finished the data ingestion piece… the next step is the transformation layer."):

```swift
        // Distinctive fixture words instead of a byte snapshot (D39):
        // extracted from the retired whisper snapshot (git history:
        // __Snapshots__/RefinementPipelineTests/bareWavEndToEnd.1.txt).
        let lower = markdown.lowercased()
        for keyword in ["coffee", "barista", "bookstore", "ingestion", "transformation"] {
            #expect(lower.contains(keyword), "final.md should mention '\(keyword)'")
        }
```

   (The pre-existing `#expect(markdown.lowercased().contains("coffee"))` line becomes redundant — delete it.)
6. Delete the `body(of:)` helper if nothing references it after the snapshot removal.
7. Update the suite doc comment: replace the "real whisper (`base` model, D4)" sentence with "real WhisperKit (`large-v3-turbo`, D39)" and the determinism paragraph's whisper.cpp specifics with "WhisperKit decodes temperature-0-first; transcript text is asserted via fixture keywords, which are robust to decoder wording drift". Keep the venv/HF_TOKEN skip explanation verbatim — `Self.makeDiarizer()` gating is untouched.

Then retire the snapshot:

```bash
git rm Tests/PipelineTests/__Snapshots__/RefinementPipelineTests/bareWavEndToEnd.1.txt
```

- [ ] **Step 7: Migrate SpeakerLibraryPipelineTests (same recipe)**

`Tests/PipelineTests/SpeakerLibraryPipelineTests.swift` has four `pipeline.run(... transcriberFactory: factory, …)` call sites (lines ~104, ~138, ~218, ~234) plus two `WhisperTestGate.model` fetches (~80, ~199) and two `factory` definitions (~93, ~210). Apply exactly the step 6 recipe: add the same `whisperKit` static + `makeTranscriber()` pair to this suite, replace `transcriberFactory: factory` with `transcriber: Self.makeTranscriber()`, `ModelCatalog.base.name`/`ModelCatalog.base.sha256` with `"large-v3-turbo"`/`""`, unwrap the `WhisperTestGate.run` wrappers, and delete the dead `modelURL`/`factory` lines. This suite's assertions are speaker-label-shaped (`Unknown #1`, library ids), not transcript-text-shaped — no keyword changes needed. Update its doc comment's whisper mentions ("whisper still runs (CPU backend, D15)" → "WhisperKit (`large-v3-turbo`) runs on the ANE"); the existing lossy text normalization helper stays (decoder punctuation drift is backend-independent).

- [ ] **Step 8: Build + run the refinement suites**

Run: `swift build`
Expected: compiles; any missed `transcriberFactory:` call site shows up here — fix it with the step 6 recipe.
Run: `swift test --filter Refinement`
Expected: PASS (suites that need the venv/HF_TOKEN skip cleanly without them, as before).
Run: `swift test --filter FinalMarkdownRewriter`
Expected: PASS.
Run: `swift test --filter Speaker`
Expected: PASS (includes the migrated SpeakerLibraryPipelineTests when the venv is present).

- [ ] **Step 9: Prove the new CLI path end-to-end (manual, real models)**

Run: `.build/debug/pulsartrace refine Tests/Fixtures/audio/single-speaker-30s.wav --model large-v3-turbo --language en` (bare; `dangerouslyDisableSandbox: true`; needs the Python venv + HF_TOKEN like any refine — see DECISIONS D9)
Expected: exits 0; `Tests/Fixtures/audio/single-speaker-30s/final.md` exists with the `<!-- pulsartrace:final -->` marker and sensible English text; `metadata.json` records `"whisper_model": "large-v3-turbo"` and `"language": "en"`. Delete the generated folder afterwards (`rm -r Tests/Fixtures/audio/single-speaker-30s` — it must not be committed).

- [ ] **Step 10: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement Sources/pulsartrace/RefineCommand.swift Sources/pulsartrace/RecordCommand.swift Tests
git commit -m "feat(refine): CLI refine on WhisperKit ANE — --language pinning, record --refine-model"
```
