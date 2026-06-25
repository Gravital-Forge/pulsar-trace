# ANE Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution mode (user-decided 2026-06-12):** subagent-driven, with fixed model roles:
> - **Implementation: Opus subagents** — dispatch one fresh subagent per task with `model: "opus"`. Never haiku.
> - **Review: the orchestrating Fable session** — after each task, review the diff in the main session (spec-compliance against the task's steps first, then code quality) before dispatching the next task. Do not delegate review to a subagent.
> - Implementation subagents run the task's own test commands (bare `swift test --filter …` — no pipes/redirects, `dangerouslyDisableSandbox: true`, per CLAUDE.md) and report real output; the orchestrator re-runs the task's verification step itself before accepting.

**Goal:** Replace the Python pyannote diarization sidecar (both the offline refine pass and the live windowed pass) with FluidAudio's `OfflineDiarizerManager` — the CoreML/ANE port of pyannote-community-1 — and delete the entire `python/` tree.

**Architecture:** A new resident `DiarizerEngine` actor (mirroring `ParakeetEngine`) owns FluidAudio's `OfflineDiarizerManager` plus the model-directory digest that becomes the new `modelRevision`. The offline `Diarizer` actor and the live `LiveDiarizer` actor are rewritten on top of it — same public seams (`diarizeSystemStream(wavPath:)`, `LiveDiarizing`), no subprocess, no venv, no HF token. The speaker library takes a clean break (schema v3): pyannote-space centroids are archived and the database reset, because WeSpeaker embeddings live in a different vector space.

**Tech Stack:** FluidAudio 0.15.2 (already pinned in Package.swift), Swift Testing, SQLite3 (built-in), swift-snapshot-testing.

---

## Decisions baked into this plan (user veto points)

These were decided autonomously (session ran in don't-ask mode). Veto before execution if wrong:

1. **Scope: both passes.** Live diarization keeps the windowed design (10 s window / 5 s step, unchanged) but runs `OfflineDiarizerManager` in-process per window. This keeps **one embedding space** across live, offline, and the speaker library (R29), keeps the R18 live library lookup working, and lets `python/` be deleted entirely. (Alternatives rejected: offline-only keeps the whole Python stack alive for a provisional feature and silently breaks R18 cross-space matching; Sortformer streaming introduces a third embedding space.)
2. **Speaker library: clean break.** Existing centroids are pyannote-space and can never match WeSpeaker embeddings (revision scoping already guarantees they'd never match — they'd just be dead rows). On first open after the migration the old `speakers.sqlite` is archived to `speakers.sqlite.pre-v3.bak` and the library starts fresh. Speakers re-emerge as `Unknown #N` on the next refine and get renamed once. No re-enrollment machinery (matches the project's clean-over-compat posture for a pre-release app).
3. **Model identity = directory digest.** The new `modelRevision` is the `DirectoryDigest` SHA-256 of `<cacheRoot>/speaker-diarization-coreml/` — content-addressed, changes exactly when the model content changes (the same Open-Question-#3 semantics the HF commit SHA provided).
4. **Thresholds are recalibrated empirically.** `SpeakerLibrary.defaultMatchThreshold` (0.7) and `LiveDiarizer.stitchThreshold` (0.55) were tuned for pyannote's embedding space. WeSpeaker cosine similarities run lower (FluidAudio's own matcher defaults to cosine *distance* 0.65 ≈ similarity 0.35). Task 8 calibrates both against the committed audio fixtures; the plan seeds **0.45** for both as the starting point.
5. **`metadata.json` schema v2.** `pyannote_model` → `diarization_model` `{id, revision}` (drops `library_version` — there is no Python library anymore). Breaking rename → `schema_version` 2. Pre-release: no compat shim.

## Key FluidAudio 0.15.2 facts (verified against the pinned checkout)

- `OfflineDiarizerManager` (`final class`, not Sendable — wrap in an actor): `init(config:)`, `prepareModels(directory:configuration:forceRedownload:)`, `process(audio: [Float])`, `process(_ url: URL)` (memory-mapped, auto-resamples to 16 kHz). Audio must be / is converted to **16 kHz mono Float32**.
- `prepareModels(directory: X)` downloads into `X.appendingPathComponent("speaker-diarization-coreml")` (`DownloadUtils` appends `Repo.diarizer.folderName`). So pass **`cacheRoot` itself**, and the models land at `<cacheRoot>/speaker-diarization-coreml/` — exactly the D10 one-cache-root layout `FluidVADRegionDetector` and `ParakeetEngine` use. Files: `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc`, `plda-parameters.json`. HF repo `FluidInference/speaker-diarization-coreml` is **public** — no token.
- `FluidAudio.DiarizationResult`: `segments: [TimedSpeakerSegment]` (`speakerId: String` = `"S1"`, `"S2"`, …; `embedding: [Float]` = the 256-d **cluster centroid**, repeated per segment; `startTimeSeconds`/`endTimeSeconds: Float`), `speakerDatabase: [String: [Float]]?` (label → 256-d centroid). Name-collides with our `DiarizationResult` — inside `PulsarTraceEngine` the local type wins unqualified lookup; qualify theirs as `FluidAudio.DiarizationResult` where needed. Same for `Speaker` / `FluidAudio.Speaker`.
- `OfflineDiarizerConfig.default` with `config.postProcessing.exclusiveSegments = false` preserves **overlap-preserving spans** (the merge's 30 % co-attribution talk-over rule consumes overlapping spans; our `exclusiveSpans` field is consumed by nothing and gets deleted).
- The offline pipeline calls `Task.checkCancellation()` throughout segmentation/embedding/PLDA — cancelling the wrapping `Task` genuinely stops compute. This is what the refine queue's pause path maps onto.
- `OfflineDiarizationError.noSpeechDetected` is thrown for silent audio — must be caught and mapped to an empty result (live windows are often silent).
- Embeddings are L2-normalized WeSpeaker vectors; `Centroid.cosineSimilarity` works on them unchanged.

## File structure

**Create:**
- `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift` — resident model actor (load + digest + `model_downloaded`)
- `Sources/PulsarTraceEngine/Diarization/DiarizationResultMapper.swift` — pure FluidAudio→PulsarTrace result mapping
- `Tests/UnitTests/DiarizationResultMapperTests.swift`
- `Tests/UnitTests/DiarizerCancelTests.swift` — cancel/timeout semantics via the operation seam
- `Tests/UnitTests/DiarizationFixtureDecoder.swift` + `Tests/PipelineTests/DiarizationFixtureDecoder.swift` — test-only JSON fixture loaders (the wire contract dies with the subprocess; the committed JSON fixtures live on as test data)
- `Tests/PipelineTests/DiarizerTestEngine.swift` — memoized engine for E2E suites (mirrors `ParakeetTestEngine`)

**Rewrite:**
- `Sources/PulsarTraceEngine/Diarization/Diarizer.swift` — engine-backed actor, same `diarizeSystemStream(wavPath:)` entry, `RefinementCancellable` kept
- `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift` — in-process windowed diarization, stitching logic kept
- `Tests/PipelineTests/DiarizationE2ETests.swift` — real-model offline + live + calibration suites

**Modify:**
- `Sources/PulsarTraceEngine/Diarization/SpeakerSpan.swift` — drop `modelVersion`, `exclusiveSpans`; comment updates
- `Sources/PulsarTraceEngine/Refinement/RefinementMetadata.swift` — `DiarizationModelInfo`, schema v2
- `Sources/PulsarTraceEngine/Refinement/TranscriptAssembly.swift:170-207` — `buildMetadata`
- `Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift` — `makeDiarizer` simplification; delete venv/dotEnv plumbing
- `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:535` — call-site update
- `Sources/PulsarTraceEngine/Streaming/StreamingPipeline.swift` — engine injection replaces subprocess config
- `Sources/pulsartrace-engine/main.swift` — engine preload replaces venv config; delete `dotEnv`
- `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerLibrary.swift` — schema v3, column rename, archive-reset migration
- `Sources/PulsarTraceEngine/SpeakerLibrary/Speaker.swift` — `pyannoteModelRevision` → `modelRevision`
- `Sources/PulsarTraceEngine/Support/Doctor.swift` + `Sources/pulsartrace/DoctorCommand.swift` — python check → model-cache check
- `docs/file-format.md`, `docs/events-schema.md`, `README.md`, `CLAUDE.md`, `project-docs/DECISIONS.md` (new D40), `project-docs/PLAN.md`, `CHANGELOG.md`

**Delete:**
- `python/` (entire tree: `pulsartrace-ai/`, `build-venv.sh`, `prefetch-model.sh`)
- `Sources/PulsarTraceEngine/Diarization/DiarizationJSON.swift`
- `Tests/UnitTests/DiarizationDecodeTests.swift`
- `Tests/PipelineTests/DiarizationE2ETests.swift` (old python-subprocess content — file is rewritten)

---

### Task 1: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Create the working branch off the ANE pipeline branch**

```bash
git checkout feat/ane-transcription-pipeline
git checkout -b feat/ane-diarization
```

(If executing via the pulsartrace-using-git-worktrees skill, create the worktree for `feat/ane-diarization` based on `feat/ane-transcription-pipeline` instead.)

- [ ] **Step 2: Verify the suite is green before touching anything**

Run each, expect all PASS (the `Parakeet`/`WhisperKitRefine` filters download models on first run):

```bash
swift test --filter UnitTests
swift test --filter Refinement
swift test --filter Speaker
```

---

### Task 2: Contract slim — `DiarizationResult` loses `modelVersion`/`exclusiveSpans`; `metadata.json` goes to schema v2

The Python wire contract carried pyannote-specific identity (`model_version` = pyannote.audio library version) and an `exclusive_spans` list nothing consumes (`DiarizedTranscript.swift:83` merges on `spans` only; `grep -rn "exclusiveSpans" Sources/` finds only the Diarization directory). Slim the Swift types *first*, while the Python diarizer still works — the JSON decoder keeps compiling by simply not passing the dropped fields.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Diarization/SpeakerSpan.swift`
- Modify: `Sources/PulsarTraceEngine/Diarization/DiarizationJSON.swift` (still alive until Task 4)
- Modify: `Sources/PulsarTraceEngine/Refinement/RefinementMetadata.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/TranscriptAssembly.swift:191-196, 204`
- Modify: `docs/file-format.md` (metadata.json section)
- Test: existing tests in `Tests/UnitTests/` + `Tests/PipelineTests/` that construct these types

- [ ] **Step 1: Find every construction/usage site of the doomed fields**

```bash
grep -rn "modelVersion\|exclusiveSpans\|exclusive_spans\|PyannoteModelInfo\|pyannoteModel\|pyannote_model" Sources/ Tests/ --include="*.swift"
```

Expected hits: `SpeakerSpan.swift`, `DiarizationJSON.swift`, `Diarizer.swift` (log line uses `result.modelVersion`), `TranscriptAssembly.swift`, `RefinementMetadata.swift`, plus tests (`DiarizationDecodeTests`, merge tests, metadata/snapshot tests). Keep the list; every hit must be edited in this task.

- [ ] **Step 2: Slim `DiarizationResult` in `SpeakerSpan.swift`**

Delete the `modelVersion` and `exclusiveSpans` stored properties, their init parameters, and their doc comments. Update the type-level doc comments: embeddings are now described as "256-d speaker embeddings from the diarization backend's embedding model (R29) — comparable only within one `modelRevision`". The resulting init:

```swift
public init(
    model: String,
    modelRevision: String = "",
    audioDuration: Duration,
    speakers: [String],
    spans: [SpeakerSpan],
    embeddings: [SpeakerEmbedding]
) {
    self.model = model
    self.modelRevision = modelRevision
    self.audioDuration = audioDuration
    self.speakers = speakers
    self.spans = spans
    self.embeddings = embeddings
}
```

`displayLabel(for:)`, `SpeakerSpan`, `SpeakerEmbedding` are unchanged.

- [ ] **Step 3: Update `DiarizationJSON.swift` to keep decoding the (still-live) Python JSON into the slim type**

In `DiarizationDecoder.decode`, drop the `modelVersion:` and `exclusiveSpans:` arguments. The `DiarizationPayload` struct keeps its `modelVersion`/`exclusiveSpans` fields (the Python side still emits them; `Decodable` needs them present or optional — leave as-is, just unused).

- [ ] **Step 4: Replace `PyannoteModelInfo` with `DiarizationModelInfo` in `RefinementMetadata.swift`**

```swift
/// Identity of the diarization model used for the refine pass.
public struct DiarizationModelInfo: Codable, Equatable, Sendable {
    /// Model id, e.g. `FluidInference/speaker-diarization-coreml`.
    public let id: String
    /// Content digest of the model directory (DirectoryDigest SHA-256) —
    /// the speaker library's centroid-compatibility key (D40).
    public let revision: String

    public init(id: String, revision: String) {
        self.id = id
        self.revision = revision
    }
}
```

Rename the field `pyannoteModel: PyannoteModelInfo?` → `diarizationModel: DiarizationModelInfo?`, its CodingKey `pyannote_model` → `diarization_model`, and bump:

```swift
/// Current schema version. v2: `pyannote_model` → `diarization_model`
/// {id, revision} (D40 — diarization moved to the ANE; the pyannote.audio
/// library version no longer exists).
public static let currentSchemaVersion = 2
```

- [ ] **Step 5: Update `TranscriptAssembly.buildMetadata` (lines 191-196, 204)**

```swift
let diarizationModel = diarization.map {
    RefinementMetadata.DiarizationModelInfo(
        id: $0.model,
        revision: $0.modelRevision)
}
```

and pass `diarizationModel: diarizationModel` in the `RefinementMetadata` init.

- [ ] **Step 6: Update the log line in `Diarizer.swift` (lines 205-209)**

The completion log reads `result.modelVersion` — change to log the span/speaker counts only:

```swift
logger.notice(
    "offline diarization complete: \(speakerCount) speaker(s), \(spanCount) span(s)")
```

- [ ] **Step 7: Fix every test from the Step 1 grep list**

Mechanical: remove `modelVersion:`/`exclusiveSpans:` arguments from `DiarizationResult` constructions; rename `pyannoteModel`/`PyannoteModelInfo` usages; update expected `schema_version` values from 1 → 2 and expected key `pyannote_model` → `diarization_model` in metadata assertions. For snapshot tests: delete the affected snapshot files reported by failing assertions, re-run to re-record, and **inspect the diff** — only the `diarization_model` key and `schema_version` should change.

- [ ] **Step 8: Run the affected suites**

```bash
swift test --filter UnitTests
swift test --filter Refinement
```

Expected: PASS.

- [ ] **Step 9: Update `docs/file-format.md`**

In the `metadata.json` section, replace the `pyannote_model` sample/field-description with:

```json
"diarization_model": {
  "id": "FluidInference/speaker-diarization-coreml",
  "revision": "<sha256 content digest of the model directory>"
}
```

and bump the documented `schema_version` to 2 with a one-line changelog note ("v2: `pyannote_model` → `diarization_model`; `library_version` dropped — D40").

- [ ] **Step 10: Commit**

```bash
git add Sources/ Tests/ docs/file-format.md
git commit -m "refactor(diarization)!: slim DiarizationResult, metadata.json v2 diarization_model"
```

---

### Task 3: `DiarizerEngine` + `DiarizationResultMapper`

The resident model owner, mirroring `ParakeetEngine` (`Sources/PulsarTraceEngine/Transcription/Parakeet/ParakeetEngine.swift`): load once per process, emit `model_downloaded` with a `DirectoryDigest` on fresh download, expose diarize calls returning **our** `DiarizationResult`. The mapper is a pure function over primitives so it unit-tests without FluidAudio types or models.

**Files:**
- Create: `Sources/PulsarTraceEngine/Diarization/DiarizationResultMapper.swift`
- Create: `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`
- Test: `Tests/UnitTests/DiarizationResultMapperTests.swift`
- Test: `Tests/PipelineTests/DiarizerTestEngine.swift` + engine suite inside `Tests/PipelineTests/DiarizationE2ETests.swift` (Task 4 rewrites that file; here, append a new file-local suite — see Step 6 note)

- [ ] **Step 1: Write the failing mapper tests**

`Tests/UnitTests/DiarizationResultMapperTests.swift`:

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("DiarizationResultMapper")
struct DiarizationResultMapperTests {

    private func seg(_ id: String, _ start: Double, _ end: Double)
        -> DiarizationResultMapper.Segment {
        .init(speakerId: id, start: start, end: end)
    }

    @Test func mapsSegmentsAndEmbeddings() {
        let result = DiarizationResultMapper.map(
            segments: [seg("S1", 0.0, 4.5), seg("S2", 4.5, 9.0)],
            speakerDatabase: ["S1": [1, 0, 0], "S2": [0, 1, 0]],
            audioDuration: .seconds(9),
            modelRevision: "abc123")
        #expect(result.model == "FluidInference/speaker-diarization-coreml")
        #expect(result.modelRevision == "abc123")
        #expect(result.speakers == ["S1", "S2"])
        #expect(result.spans == [
            SpeakerSpan(speaker: "S1", start: .zero, end: .milliseconds(4500)),
            SpeakerSpan(speaker: "S2", start: .milliseconds(4500), end: .milliseconds(9000)),
        ])
        #expect(result.embeddings == [
            SpeakerEmbedding(speaker: "S1", vector: [1, 0, 0]),
            SpeakerEmbedding(speaker: "S2", vector: [0, 1, 0]),
        ])
    }

    @Test func speakersSortNaturally() {
        // "S10" must sort after "S2" (lexicographic would invert them, which
        // would scramble Speaker_N display labels past 9 speakers).
        let segments = (1...10).map { seg("S\($0)", Double($0), Double($0) + 1) }
        let result = DiarizationResultMapper.map(
            segments: segments, speakerDatabase: [:],
            audioDuration: .seconds(12), modelRevision: "")
        #expect(result.speakers == (1...10).map { "S\($0)" })
    }

    @Test func dropsNonFiniteAndOrphanEmbeddings() {
        // A NaN vector is dropped (mirrors the old Python sanitization);
        // an embedding for a label with no spans is dropped too.
        let result = DiarizationResultMapper.map(
            segments: [seg("S1", 0, 1)],
            speakerDatabase: ["S1": [Float.nan, 1], "S9": [1, 0]],
            audioDuration: .seconds(1), modelRevision: "")
        #expect(result.embeddings.isEmpty)
        #expect(result.speakers == ["S1"])
    }

    @Test func spansAreSortedByStart() {
        let result = DiarizationResultMapper.map(
            segments: [seg("S2", 5, 6), seg("S1", 0, 1)],
            speakerDatabase: [:],
            audioDuration: .seconds(6), modelRevision: "")
        #expect(result.spans.map(\.speaker) == ["S1", "S2"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DiarizationResultMapper`
Expected: FAIL — `DiarizationResultMapper` not defined.

- [ ] **Step 3: Implement the mapper**

`Sources/PulsarTraceEngine/Diarization/DiarizationResultMapper.swift`:

```swift
import Foundation

/// Maps FluidAudio's offline diarization output into the engine's
/// `DiarizationResult`. Pure — takes primitives, not FluidAudio types — so it
/// unit-tests without CoreML models and without the
/// `FluidAudio.DiarizationResult` name collision leaking past `DiarizerEngine`.
enum DiarizationResultMapper {

    /// The model id recorded in `DiarizationResult.model` /
    /// `metadata.json.diarization_model.id`.
    static let modelId = "FluidInference/speaker-diarization-coreml"

    /// One FluidAudio segment, reduced to primitives.
    struct Segment {
        let speakerId: String   // "S1", "S2", …
        let start: Double       // seconds
        let end: Double         // seconds
    }

    /// Build the engine-facing result.
    ///
    /// - `speakers` are natural-sorted ("S2" before "S10") so positional
    ///   `Speaker_N` display labels and the reconciler's deterministic
    ///   `Unknown #N` numbering stay stable past 9 speakers.
    /// - Embeddings are dropped when non-finite (defence mirroring the old
    ///   Python `_embeddings_by_label` NaN guard) or when their label has no
    ///   spans (an embedding nothing references is dead weight).
    static func map(
        segments: [Segment],
        speakerDatabase: [String: [Float]],
        audioDuration: Duration,
        modelRevision: String
    ) -> DiarizationResult {
        let labels = Set(segments.map(\.speakerId))
        let speakers = labels.sorted { naturalKey($0) < naturalKey($1) }
        let spans = segments
            .map {
                SpeakerSpan(
                    speaker: $0.speakerId,
                    start: duration($0.start),
                    end: duration($0.end))
            }
            .sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
        let embeddings = speakerDatabase
            .filter { labels.contains($0.key) }
            .filter { !$0.value.isEmpty && $0.value.allSatisfy(\.isFinite) }
            .map { SpeakerEmbedding(speaker: $0.key, vector: $0.value) }
            .sorted { $0.speaker < $1.speaker }
        return DiarizationResult(
            model: modelId,
            modelRevision: modelRevision,
            audioDuration: audioDuration,
            speakers: speakers,
            spans: spans,
            embeddings: embeddings)
    }

    /// Sort key making "S2" < "S10": the numeric suffix when present, else
    /// the label itself (labels FluidAudio doesn't emit today sort last,
    /// lexicographically).
    private static func naturalKey(_ label: String) -> (Int, String) {
        guard label.hasPrefix("S"), let n = Int(label.dropFirst()) else {
            return (Int.max, label)
        }
        return (n, label)
    }

    private static func duration(_ seconds: Double) -> Duration {
        .milliseconds(Int((seconds * 1000).rounded()))
    }
}
```

Note: `($0.start, $0.speaker) < (…)` needs `Duration` to be `Comparable` (it is).

- [ ] **Step 4: Run the mapper tests**

Run: `swift test --filter DiarizationResultMapper`
Expected: PASS.

- [ ] **Step 5: Implement `DiarizerEngine`**

`Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`:

```swift
import FluidAudio
import Foundation
import Logging

/// The resident FluidAudio offline-diarization stack (D40) — pyannote
/// community-1 ported to CoreML, segmentation + WeSpeaker embeddings + VBx
/// clustering on the ANE. Loaded once per process and shared by the offline
/// refine pass (`Diarizer`) and the live windowed pass (`LiveDiarizer`), so
/// both produce embeddings in the same vector space (R29).
///
/// `OfflineDiarizerManager` is a non-Sendable class; this actor owns it and
/// serializes access. Models live at `<cacheRoot>/speaker-diarization-coreml/`
/// (FluidAudio's `DownloadUtils` appends the repo folder name to the directory
/// it is handed) — the same D10 cache root Parakeet and FluidVAD use.
public actor DiarizerEngine {

    /// The model name recorded in `model_downloaded` events.
    public static let modelName = "speaker-diarization-coreml"
    /// The on-disk repo folder under the cache root.
    public static let repoFolderName = "speaker-diarization-coreml"
    /// Model bundles whose presence marks the cache as already populated.
    private static let requiredBundles = [
        "Segmentation.mlmodelc", "FBank.mlmodelc",
        "Embedding.mlmodelc", "PldaRho.mlmodelc",
    ]

    private let manager: OfflineDiarizerManager
    /// Content digest of the model directory — the authoritative model
    /// identity. The speaker library keys centroid compatibility on this
    /// (Open Question #3 / D40): it changes exactly when the model content
    /// changes.
    public let modelRevision: String

    private init(manager: OfflineDiarizerManager, modelRevision: String) {
        self.manager = manager
        self.modelRevision = modelRevision
    }

    /// Download (first run only; ~a few hundred MB from huggingface.co — the
    /// permitted model-download network call; the repo is public, no token)
    /// and load the diarizer models from
    /// `<cacheRoot>/speaker-diarization-coreml`. Emits `model_downloaded`
    /// with a `DirectoryDigest` after a fresh download (D39 digest pattern).
    ///
    /// Call once per process and share the returned engine.
    public static func load(
        cacheRoot: URL,
        events: EventWriter?,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) async throws -> DiarizerEngine {
        let modelDir = cacheRoot.appendingPathComponent(
            repoFolderName, isDirectory: true)
        let existedBefore = requiredBundles.allSatisfy {
            FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent($0).path)
        }

        logger.notice("diarizer: ensuring models available (cached=\(existedBefore))")
        var config = OfflineDiarizerConfig.default
        // Keep overlap-preserving spans: the transcript merge's 30 %
        // co-attribution rule (D11) needs overlapping speaker spans.
        config.postProcessing.exclusiveSegments = false
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: cacheRoot)

        // The digest is required (not best-effort like Parakeet's): it IS the
        // modelRevision the speaker library scopes centroids by.
        let digest = try DirectoryDigest.compute(at: modelDir)
        if !existedBefore, let events {
            _ = try? await events.append(ModelDownloadedEvent(
                modelName: modelName,
                sizeBytes: digest.totalBytes,
                sha256: digest.sha256,
                sourceHost: "huggingface.co"))
        }
        logger.notice("diarizer: models resident (revision \(digest.sha256.prefix(12))…)")
        return DiarizerEngine(manager: manager, modelRevision: digest.sha256)
    }

    /// Diarize a buffer of 16 kHz mono Float32 samples (the live windowed
    /// path). Silent audio yields an empty result, never an error.
    public func diarize(samples: [Float]) async throws -> DiarizationResult {
        let duration = Duration.milliseconds(
            samples.count * 1000 / AudioFormat.sampleRate)
        do {
            let raw = try await manager.process(audio: samples)
            return mapped(raw, audioDuration: duration)
        } catch let e as OfflineDiarizationError {
            if case .noSpeechDetected = e {
                return emptyResult(audioDuration: duration)
            }
            throw e
        }
    }

    /// Diarize a WAV file (the offline refine path). FluidAudio memory-maps
    /// and resamples to 16 kHz itself, so arbitrary input WAVs are fine.
    /// Silent audio yields an empty result, never an error.
    public func diarize(wavPath: URL) async throws -> DiarizationResult {
        let seconds = WAVReader.probeDurationSeconds(at: wavPath) ?? 0
        let duration = Duration.milliseconds(Int((seconds * 1000).rounded()))
        do {
            let raw = try await manager.process(wavPath)
            return mapped(raw, audioDuration: duration)
        } catch let e as OfflineDiarizationError {
            if case .noSpeechDetected = e {
                return emptyResult(audioDuration: duration)
            }
            throw e
        }
    }

    private func mapped(
        _ raw: FluidAudio.DiarizationResult, audioDuration: Duration
    ) -> DiarizationResult {
        DiarizationResultMapper.map(
            segments: raw.segments.map {
                .init(
                    speakerId: $0.speakerId,
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds))
            },
            speakerDatabase: raw.speakerDatabase ?? [:],
            audioDuration: audioDuration,
            modelRevision: modelRevision)
    }

    private func emptyResult(audioDuration: Duration) -> DiarizationResult {
        DiarizationResultMapper.map(
            segments: [], speakerDatabase: [:],
            audioDuration: audioDuration, modelRevision: modelRevision)
    }
}
```

Build check: `swift build` — expect success. If `case .noSpeechDetected` does not pattern-match (enum case carries no payload vs payload), check the case's shape in the checkout's `OfflineDiarizerTypes.swift` and match accordingly (`catch OfflineDiarizationError.noSpeechDetected` if payload-free).

- [ ] **Step 6: Add the memoized test engine + the gated engine E2E test**

`Tests/PipelineTests/DiarizerTestEngine.swift`:

```swift
import Logging
@testable import PulsarTraceEngine

/// One resident diarizer engine per test process, shared by every
/// DiarizationE2E suite. Memoizing the Task (not the engine) makes a second
/// concurrent first-caller await the in-flight load instead of racing a
/// duplicate model download. First run downloads the
/// `speaker-diarization-coreml` bundles (~a few hundred MB) into the standard
/// cache root — subsequent runs are offline.
enum DiarizerTestEngine {
    private static let task = Task<DiarizerEngine, Error> {
        try await DiarizerEngine.load(
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            events: nil,
            logger: Logger(label: "test.diarizer"))
    }

    static func shared() async throws -> DiarizerEngine {
        try await task.value
    }
}
```

Then append a **new suite** at the bottom of the existing `Tests/PipelineTests/DiarizationE2ETests.swift` (the old python suites in that file still compile and still skip-or-pass; they are deleted in Task 4):

```swift
@Suite("DiarizationE2E engine load", .serialized)
struct DiarizationE2EEngineTests {

    @Test func loadsAndReportsContentRevision() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let revision = await engine.modelRevision
        #expect(revision.count == 64)   // SHA-256 hex
        #expect(revision.allSatisfy(\.isHexDigit))
    }

    @Test func revisionIsStableAcrossLoads() async throws {
        let first = try await DiarizerTestEngine.shared()
        let second = try await DiarizerEngine.load(
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            events: nil)
        #expect(await first.modelRevision == (await second.modelRevision))
    }
}
```

- [ ] **Step 7: Run the engine tests (downloads models on first run)**

Run: `swift test --filter DiarizationE2E`
Expected: PASS (old python suites skip gracefully when venv/HF_TOKEN absent — same as before; the two new tests pass after the model download).

- [ ] **Step 8: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/ Tests/
git commit -m "feat(diarization): DiarizerEngine — FluidAudio community-1 on the ANE, digest-keyed revision"
```

---

### Task 4: Rewrite the offline `Diarizer` on the engine; retire the Python wire contract

Same actor name, same single entry point `diarizeSystemStream(wavPath:)` (R17 structurally intact), same `RefinementCancellable` conformance — but in-process. Cancellation maps onto `Task` cancellation (FluidAudio checks it); the timeout watchdog survives as a cheap deadline (effective timeout = max(configured floor, audio real-time length), exactly the old rule).

**Files:**
- Rewrite: `Sources/PulsarTraceEngine/Diarization/Diarizer.swift`
- Delete: `Sources/PulsarTraceEngine/Diarization/DiarizationJSON.swift`
- Delete: `Tests/UnitTests/DiarizationDecodeTests.swift`
- Create: `Tests/UnitTests/DiarizationFixtureDecoder.swift`, `Tests/PipelineTests/DiarizationFixtureDecoder.swift`
- Create: `Tests/UnitTests/DiarizerCancelTests.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift`, `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:535`
- Rewrite: `Tests/PipelineTests/DiarizationE2ETests.swift` (python suites → FluidAudio offline suites)

- [ ] **Step 1: Inventory the blast radius**

```bash
grep -rn "DiarizeError\|Diarizer.Configuration\|Diarizer(" Sources/ Tests/ --include="*.swift" | grep -v LiveDiarizer
grep -rn "DiarizationDecoder" Sources/ Tests/ --include="*.swift"
```

Known Sources call sites: `OfflineRefiner.swift:92,125-159` (construction), `RefinementJobQueue.swift:535-541` (construction + `setInflightCancellable`), `ResumableRefiner.swift:319-320` (catches `.cancelled` — case survives, no change needed), `RefinementPipeline.swift:175-282` (takes `diarizer: Diarizer`, calls `diarizeSystemStream` — no change needed). Tests constructing `Diarizer.Configuration` with python paths must be updated to `.init()` or `.init(cacheRoot:timeout:)`.

- [ ] **Step 2: Write the failing cancel/timeout unit tests (operation seam)**

`Tests/UnitTests/DiarizerCancelTests.swift`:

```swift
import Foundation
import Testing
@testable import PulsarTraceEngine

@Suite("Diarizer cancellation and timeout")
struct DiarizerCancelTests {

    /// A real (tiny) WAV so the existence guard passes.
    private func makeWAV(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("tiny.wav")
        try WAVWriter.write(
            samples: [Float](repeating: 0, count: AudioFormat.sampleRate / 10),
            to: url)
        return url
    }

    @Test func cancelThrowsCancelled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeWAV(in: dir)

        let diarizer = Diarizer(
            configuration: .init(timeout: .seconds(600)),
            operation: { _ in
                try await Task.sleep(for: .seconds(60))
                return DiarizationResultMapper.map(
                    segments: [], speakerDatabase: [:],
                    audioDuration: .zero, modelRevision: "")
            })
        let run = Task { try await diarizer.diarizeSystemStream(wavPath: wav) }
        try await Task.sleep(for: .milliseconds(200))   // let it get in flight
        await diarizer.cancel()

        await #expect(throws: Diarizer.DiarizeError.cancelled) {
            try await run.value
        }
    }

    @Test func timeoutThrowsTimedOut() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try makeWAV(in: dir)

        // 0.1 s of audio keeps the effective timeout at the 1 s floor.
        let diarizer = Diarizer(
            configuration: .init(timeout: .seconds(1)),
            operation: { _ in
                try await Task.sleep(for: .seconds(60))
                return DiarizationResultMapper.map(
                    segments: [], speakerDatabase: [:],
                    audioDuration: .zero, modelRevision: "")
            })
        await #expect(throws: Diarizer.DiarizeError.timedOut(seconds: 1)) {
            try await diarizer.diarizeSystemStream(wavPath: wav)
        }
    }

    @Test func missingWAVThrowsWavNotFound() async throws {
        let diarizer = Diarizer(configuration: .init())
        await #expect(throws: Diarizer.DiarizeError.self) {
            try await diarizer.diarizeSystemStream(
                wavPath: URL(fileURLWithPath: "/nonexistent/x.wav"))
        }
    }
}
```

(If `WAVWriter.write(samples:to:)` has a different signature, mirror the call in `LiveDiarizer.swift:306` exactly.)

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter DiarizerCancel`
Expected: FAIL — `Diarizer` has no `operation:` initializer / no such `DiarizeError` cases.

- [ ] **Step 4: Rewrite `Sources/PulsarTraceEngine/Diarization/Diarizer.swift`**

Replace the whole file:

```swift
import Foundation
import Logging

/// Runs offline speaker diarization in-process on the ANE (D40).
///
/// Architecture:
/// - FluidAudio's offline pipeline (pyannote community-1 ported to CoreML —
///   `DiarizerEngine`) replaces the captive Python subprocess (D9, retired).
///   No venv, no HF token, no IPC: the WAV is handed to CoreML directly.
/// - **R17**: the entry point only ever receives the *system-stream* WAV. The
///   mic stream is never diarized — "You" is always "You". This is structural:
///   `Diarizer` has a single `diarizeSystemStream(wavPath:)` method and no
///   other diarization surface.
/// - **Cancellation** (queue pause, D-Q7): `cancel()` cancels the in-flight
///   `Task`; FluidAudio's pipeline checks `Task.checkCancellation()` between
///   chunks, so compute genuinely stops. The caller sees `.cancelled`, retries
///   when the pause gate reopens.
/// - **Timeout**: a watchdog cancels the work at max(configured floor, the
///   audio's real-time length) — the same budget rule the subprocess had.
///
/// An `actor`: the engine load slot, the in-flight task, and the cancel flag
/// are mutable state shared across calls.
public actor Diarizer {

    public struct Configuration: Sendable {
        /// Model cache root (D10) — models live in
        /// `<cacheRoot>/speaker-diarization-coreml/`.
        public let cacheRoot: URL
        /// Minimum wall-clock budget for one diarization run. Used as a
        /// *floor*: the actual budget is at least the input WAV's real-time
        /// duration. At 60×+ real-time on the ANE this only trips when
        /// something is genuinely wedged.
        public let timeout: Duration

        public init(
            cacheRoot: URL = AppPaths.standard.modelsCacheDirectory,
            timeout: Duration = .seconds(600)
        ) {
            self.cacheRoot = cacheRoot
            self.timeout = timeout
        }
    }

    public enum DiarizeError: Error, CustomStringConvertible, Equatable {
        case wavNotFound(String)
        case modelLoadFailed(String)
        case processingFailed(String)
        case timedOut(seconds: Int)
        /// The run was terminated by a `cancel()` call (queue pause). Distinct
        /// from `.processingFailed` so the refiner can distinguish a pause
        /// from a real failure and retry when the gate reopens.
        case cancelled

        public var description: String {
            switch self {
            case .wavNotFound(let p): return "diarization WAV not found: \(p)"
            case .modelLoadFailed(let m):
                return "diarization model load failed: \(m)"
            case .processingFailed(let m): return "diarization failed: \(m)"
            case .timedOut(let s): return "diarization timed out after \(s)s"
            case .cancelled: return "diarization cancelled (paused by queue)"
            }
        }
    }

    /// Test seam: replaces the engine-backed diarize call so cancellation and
    /// timeout semantics are testable without CoreML models.
    typealias Operation = @Sendable (URL) async throws -> DiarizationResult

    private let configuration: Configuration
    private let events: EventWriter?
    private let logger: Logger
    private let operationOverride: Operation?
    /// Memoized engine load — cleared on failure so a retry can reload
    /// (same pattern as `FluidVADRegionDetector.ensureManager`).
    private var engineTask: Task<DiarizerEngine, Error>?
    private var inflight: Task<DiarizationResult, Error>?
    private var cancelledFlag = false
    private var timedOutFlag = false

    public init(
        configuration: Configuration,
        events: EventWriter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.configuration = configuration
        self.events = events
        self.logger = logger
        self.operationOverride = nil
    }

    /// Test-seam initializer.
    init(
        configuration: Configuration,
        events: EventWriter? = nil,
        logger: Logger = Logger(label: LogSubsystem.engine),
        operation: @escaping Operation
    ) {
        self.configuration = configuration
        self.events = events
        self.logger = logger
        self.operationOverride = operation
    }

    /// Cancel the in-flight diarization. A no-op when nothing is running.
    /// The run currently in flight throws `DiarizeError.cancelled`.
    public func cancel() {
        cancelledFlag = true
        inflight?.cancel()
    }

    /// Diarize the **system-stream** WAV of a recording (R17).
    public func diarizeSystemStream(wavPath: URL) async throws -> DiarizationResult {
        guard FileManager.default.fileExists(atPath: wavPath.path) else {
            throw DiarizeError.wavNotFound(wavPath.path)
        }
        cancelledFlag = false
        timedOutFlag = false

        let timeout = effectiveTimeout(for: wavPath)
        let timeoutSeconds = Int(timeout.components.seconds)
        logger.notice(
            "offline diarization: FluidAudio community-1 on ANE (budget \(timeoutSeconds)s)")

        let operation = try await resolveOperation()
        let work = Task { try await operation(wavPath) }
        inflight = work
        defer { inflight = nil }

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            await self.noteTimeout()
        }
        defer { watchdog.cancel() }

        do {
            let result = try await work.value
            let speakerCount = result.speakers.count
            let spanCount = result.spans.count
            logger.notice(
                "offline diarization complete: \(speakerCount) speaker(s), \(spanCount) span(s)")
            return result
        } catch is CancellationError {
            if cancelledFlag { throw DiarizeError.cancelled }
            if timedOutFlag { throw DiarizeError.timedOut(seconds: timeoutSeconds) }
            throw DiarizeError.cancelled
        } catch let e as DiarizeError {
            throw e
        } catch {
            if cancelledFlag { throw DiarizeError.cancelled }
            if timedOutFlag { throw DiarizeError.timedOut(seconds: timeoutSeconds) }
            throw DiarizeError.processingFailed(String(describing: error))
        }
    }

    /// The engine-backed operation, or the test seam.
    private func resolveOperation() async throws -> Operation {
        if let operationOverride { return operationOverride }
        let engine = try await ensureEngine()
        return { wavPath in try await engine.diarize(wavPath: wavPath) }
    }

    private func ensureEngine() async throws -> DiarizerEngine {
        if let engineTask {
            do { return try await engineTask.value }
            catch {
                if self.engineTask == engineTask { self.engineTask = nil }
                throw DiarizeError.modelLoadFailed(String(describing: error))
            }
        }
        let configuration = self.configuration
        let events = self.events
        let logger = self.logger
        let task = Task {
            try await DiarizerEngine.load(
                cacheRoot: configuration.cacheRoot, events: events, logger: logger)
        }
        engineTask = task
        do { return try await task.value }
        catch {
            if self.engineTask == task { self.engineTask = nil }
            throw DiarizeError.modelLoadFailed(String(describing: error))
        }
    }

    private func noteTimeout() {
        timedOutFlag = true
        inflight?.cancel()
    }

    /// Expand `configuration.timeout` to at least the audio's real-time
    /// length, so an 80-minute meeting is not killed by a 10-minute ceiling.
    private func effectiveTimeout(for wavPath: URL) -> Duration {
        let configured = configuration.timeout
        guard let audioSeconds = WAVReader.probeDurationSeconds(at: wavPath),
              audioSeconds.isFinite, audioSeconds > 0 else {
            return configured
        }
        let configuredSeconds = Double(configured.components.seconds)
        guard audioSeconds > configuredSeconds else { return configured }
        return .seconds(Int(audioSeconds.rounded(.up)))
    }
}

// MARK: - RefinementCancellable

extension Diarizer: RefinementCancellable {}
// `cancel()` is sync on `Diarizer`; async protocol methods accept sync
// implementations, so no wrapper is needed.
```

Note the deleted pieces: `redactingPaths(in:)` had a second user — `LiveDiarizer.swift:241,351` calls `Diarizer.redactingPaths`. Those call sites die in Task 5; **until then**, keep the old static function by appending it temporarily:

```swift
extension Diarizer {
    /// Transitional — only `LiveDiarizer` (rewritten in the next task) still
    /// calls this. Deleted with it.
    static func redactingPaths(in line: String) -> String {
        line
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> Substring in
                guard token.hasPrefix("/"), token.count > 1 else { return token }
                if let lastSlash = token.lastIndex(of: "/") {
                    let base = token[token.index(after: lastSlash)...]
                    return base.isEmpty ? token : base
                }
                return token
            }
            .joined(separator: " ")
    }
}
```

- [ ] **Step 5: Delete the wire contract; move fixture decoding into the test targets**

```bash
git rm Sources/PulsarTraceEngine/Diarization/DiarizationJSON.swift
git rm Tests/UnitTests/DiarizationDecodeTests.swift
```

Create `Tests/UnitTests/DiarizationFixtureDecoder.swift` **and** an identical copy at `Tests/PipelineTests/DiarizationFixtureDecoder.swift` (the two test targets cannot share sources; ~50 duplicated lines is the accepted cost):

```swift
import Foundation
@testable import PulsarTraceEngine

/// Decodes the committed diarization JSON fixtures
/// (`Tests/Fixtures/diarization/*.json`) into a `DiarizationResult`.
///
/// These files were captured from the retired Python pyannote pipeline (D40).
/// They are no longer a wire contract — just frozen, realistic test data for
/// the merge / reconciliation logic, which is embedding-space-agnostic.
/// Unknown keys in the files (`schema`, `model_version`, `exclusive_spans`)
/// are deliberately ignored.
enum DiarizationFixtureDecoder {

    private struct Payload: Decodable {
        struct Span: Decodable {
            let speaker: String
            let start: Double
            let end: Double
        }
        let model: String
        let modelRevision: String?
        let audioDuration: Double
        let speakers: [String]
        let spans: [Span]
        let embeddings: [String: [Double]]

        enum CodingKeys: String, CodingKey {
            case model
            case modelRevision = "model_revision"
            case audioDuration = "audio_duration"
            case speakers
            case spans
            case embeddings
        }
    }

    static func decode(_ data: Data) throws -> DiarizationResult {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return DiarizationResult(
            model: payload.model,
            modelRevision: payload.modelRevision ?? "",
            audioDuration: .milliseconds(Int((payload.audioDuration * 1000).rounded())),
            speakers: payload.speakers,
            spans: payload.spans.map {
                SpeakerSpan(
                    speaker: $0.speaker,
                    start: .milliseconds(Int(($0.start * 1000).rounded())),
                    end: .milliseconds(Int(($0.end * 1000).rounded())))
            },
            embeddings: payload.embeddings
                .map { SpeakerEmbedding(speaker: $0.key, vector: $0.value.map(Float.init)) }
                .sorted { $0.speaker < $1.speaker })
    }
}
```

Then re-point every `DiarizationDecoder.decode(` call in tests (from the Step 1 grep: `Tests/UnitTests/DiarizationMergeTests.swift:118,130`, `Tests/PipelineTests/DiarizationMergePipelineTests.swift:54,72,87`, `Tests/PipelineTests/SpeakerLibraryPipelineTests.swift:45`) to `DiarizationFixtureDecoder.decode(`.

- [ ] **Step 6: Update the production construction sites**

`Sources/PulsarTraceEngine/Refinement/OfflineRefiner.swift` — replace `makeDiarizer` (lines 119-160) and **delete** `repoRootURL()` (lines 162-178) and `dotEnv(repoRoot:)` (lines 180-202):

```swift
// MARK: - Diarizer wiring

/// Build a `Diarizer` over the FluidAudio ANE backend (D40). Models load
/// lazily from the shared cache root (D10) on the first diarize call;
/// `events` receives `model_downloaded` after a fresh download.
public static func makeDiarizer(events: EventWriter? = nil) -> Diarizer {
    Diarizer(configuration: .init(), events: events)
}
```

Update line 92: `let diarizer = try Self.makeDiarizer()` → `let diarizer = Self.makeDiarizer(events: events)`. Update the class doc comment (lines 17-23): drop the venv/`.env`/`PULSARTRACE_VENV_PYTHON` paragraphs (the `PULSARTRACE_REPO_ROOT`/`HF_TOKEN` overrides existed solely for the Python sidecar).

`Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:535`: `let diarizer = try OfflineRefiner.makeDiarizer()` → `let diarizer = OfflineRefiner.makeDiarizer(events: <the queue's events writer — match the surrounding code's property name>)`. If the surrounding `do/catch` only existed for this `try`, simplify it.

- [ ] **Step 7: Rewrite `Tests/PipelineTests/DiarizationE2ETests.swift`**

Replace the python-subprocess suites entirely (keep the `DiarizationE2EEngineTests` suite added in Task 3):

```swift
import Foundation
import Logging
import Testing
@testable import PulsarTraceEngine

/// End-to-end offline diarization on the committed audio fixtures, against
/// the real FluidAudio CoreML models (first run downloads them — see
/// CLAUDE.md's narrow-filter notes). Replaces the retired Python pyannote
/// subprocess suite (D40).
@Suite("DiarizationE2E (FluidAudio offline, real models)", .serialized)
struct DiarizationE2ETests {

    private func fixtureURL(_ name: String) -> URL {
        // Mirror the path resolution the old suite used (repo-root relative
        // via #filePath): Tests/Fixtures/audio/<name>.wav
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // PipelineTests
            .deletingLastPathComponent()    // Tests
            .appendingPathComponent("Fixtures/audio/\(name).wav")
    }

    @Test func twoSpeakersAlternating() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let result = try await engine.diarize(
            wavPath: fixtureURL("two-speakers-alternating"))

        #expect(result.speakers.count == 2)
        #expect(!result.spans.isEmpty)
        #expect(result.embeddings.count == 2)
        #expect(result.embeddings.allSatisfy { $0.vector.count == 256 })
        #expect(result.modelRevision.count == 64)
        // Spans must cover a meaningful share of a 24 s two-speaker clip.
        let covered = result.spans.reduce(0.0) { $0 + ($1.end - $1.start).seconds }
        #expect(covered > 10.0)
    }

    @Test func singleSpeaker() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let result = try await engine.diarize(
            wavPath: fixtureURL("single-speaker-30s"))
        #expect(result.speakers.count == 1)
        #expect(result.embeddings.count == 1)
    }

    @Test func silenceYieldsEmptyResultNotError() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let result = try await engine.diarize(
            samples: [Float](repeating: 0, count: AudioFormat.sampleRate * 3))
        #expect(result.speakers.isEmpty)
        #expect(result.spans.isEmpty)
    }

    @Test func diarizerActorEndToEnd() async throws {
        // Through the production `Diarizer` actor (lazy engine load path).
        let diarizer = Diarizer(configuration: .init())
        let result = try await diarizer.diarizeSystemStream(
            wavPath: fixtureURL("two-speakers-alternating"))
        #expect(result.speakers.count == 2)
    }
}
```

(Adjust `fixtureURL` to reuse the existing locator helper in this target if one exists — check the old file's resolution code before deleting it and keep that mechanism.)

- [ ] **Step 8: Fix remaining compile fallout in tests**

```bash
swift build --build-tests
```

Expect failures at every test still constructing the old `Diarizer.Configuration(pythonExecutable:…)` (e.g. timeout/cancel pipeline tests, refinement-pipeline tests passing a dummy diarizer). Replace with `Diarizer(configuration: .init())` where the diarizer is never invoked (the `precomputedDiarization` seam), or with the `operation:` seam where subprocess behaviour was being faked. Delete any test whose entire subject was subprocess mechanics (stderr piping, `[python]` log tagging, nonZeroExit) — note each deletion in the commit message.

- [ ] **Step 9: Run the suites**

```bash
swift test --filter UnitTests
swift test --filter Refinement
swift test --filter DiarizationE2E
```

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A Sources/ Tests/
git commit -m "feat(diarization)!: offline refine diarizes in-process on the ANE; python wire contract retired"
```

---

### Task 5: Rewrite `LiveDiarizer` in-process; wire the engine through `StreamingPipeline` and `main.swift`

The windowed design, stitching algorithm, provisional keys (`Them`, `Them #2`), `LiveDiarizing` protocol, and the `_seedForTesting` seam all survive verbatim. What dies: the subprocess, the scratch WAVs, `AsyncLineReader`, the ready-handshake, and the venv config.

**Files:**
- Rewrite: `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift`
- Modify: `Sources/PulsarTraceEngine/Streaming/StreamingPipeline.swift` (lines 44-75, 142-160)
- Modify: `Sources/pulsartrace-engine/main.swift` (lines 164-170, 232-291)
- Test: live window suite in `Tests/PipelineTests/DiarizationE2ETests.swift`

- [ ] **Step 1: Check for other `AsyncLineReader` / venv-config users**

```bash
grep -rn "AsyncLineReader\|LiveDiarizer.Configuration\|liveDiarizerConfig" Sources/ Tests/ --include="*.swift"
```

If `AsyncLineReader` has users outside `LiveDiarizer.swift`, move it to its own file instead of deleting. Tests constructing `LiveDiarizer.Configuration` must be updated in Step 6.

- [ ] **Step 2: Write the failing live E2E test**

Append to `Tests/PipelineTests/DiarizationE2ETests.swift`:

```swift
@Suite("DiarizationE2E live windowed", .serialized)
struct DiarizationE2ELiveTests {

    @Test func windowedPassYieldsStableProvisionalKeys() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let live = LiveDiarizer(engine: engine)

        // Drive the fixture through the production window geometry
        // (10 s window / 5 s step — StreamingPipeline defaults).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio/two-speakers-alternating.wav")
        let source = FixturePlaybackSource(file: url, realtime: false)
        let samples = try await OfflineTranscriptionPipeline(
            logger: Logger(label: "test")).accumulate(source)

        let window = AudioFormat.sampleRate * 10
        let step = AudioFormat.sampleRate * 5
        var spans: [LiveSpeakerSpan] = []
        var start = 0
        while start + window <= samples.count {
            let result = await live.diarizeWindow(
                samples: Array(samples[start..<(start + window)]),
                windowStart: .milliseconds(start * 1000 / AudioFormat.sampleRate))
            spans.append(contentsOf: result)
            start += step
        }

        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.provisionalKey.hasPrefix("Them") })
        // Spans are recording-absolute: a window starting at 10 s must not
        // emit spans inside [0, 10).
        #expect(spans.filter { $0.start >= .seconds(10) }.count > 0)
        let centroids = await live.centroids()
        #expect(!centroids.isEmpty)
        #expect(await live.modelRevision().count == 64)
    }
}
```

(Verify `OfflineTranscriptionPipeline`'s init/`accumulate` signatures against `Sources/PulsarTraceEngine/Transcription/OfflineTranscriptionPipeline.swift` and `RefinementPipeline.swift:433-435` before running; mirror that call shape.)

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter DiarizationE2ELive`
Expected: FAIL — `LiveDiarizer` has no `init(engine:)`.

- [ ] **Step 4: Rewrite `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift`**

Keep `LiveSpeakerSpan` (update its `embedding` doc comment: "The speaker embedding for this window's speaker (256-d, WeSpeaker space — R29)") and the `LiveDiarizing` protocol verbatim (update the `modelRevision()` doc line to "The diarization model's content digest (R18 revision scoping)"). Replace the `LiveDiarizer` actor and delete `AsyncLineReader`:

```swift
/// Live (streaming) speaker diarization for the system stream (R15, R16).
///
/// ## Windowed in-process diarization (D40)
///
/// The retired design ran windowed-pyannote in a long-lived Python subprocess
/// (D19). The window geometry survives — `StreamingPipeline` hands this actor
/// a ~10 s window of recent system audio every ~5 s — but each window now runs
/// FluidAudio's offline pipeline (`DiarizerEngine`) in-process on the ANE.
/// Same embedding space as the offline post-pass and the speaker library
/// (R29), no subprocess, no scratch WAVs.
///
/// ## Provisional label stitching
///
/// Per-window labels (`S1`, `S2`, …) are **not stable** across windows.
/// `LiveDiarizer` stitches them into stable per-recording keys (`Them`,
/// `Them #2`, …) by matching each window-speaker's embedding against the
/// running set of live speakers' centroids by cosine similarity. A new voice
/// that matches nothing gets a fresh `Them #N`. This is **best-effort**; the
/// post-pass is the source of truth (R16).
///
/// An `actor`: it owns the running live-speaker set, mutable state not safe
/// to touch concurrently.
public actor LiveDiarizer: LiveDiarizing {

    /// Tunables. The engine (model residency) is injected, not configured —
    /// `pulsartrace-engine` loads it once per process next to Parakeet.
    public struct Configuration: Sendable {
        /// Per-window decode ceiling. A window that overruns this is given up
        /// on (the live pass stays provisional anyway).
        public let windowTimeout: Duration

        public init(windowTimeout: Duration = .seconds(30)) {
            self.windowTimeout = windowTimeout
        }
    }

    /// Cosine-similarity threshold for stitching a window-speaker to an
    /// existing live speaker. Above → same speaker; below → a new `Them #N`.
    /// Calibrated for the WeSpeaker embedding space (D40) — see the
    /// DiarizationE2E calibration suite.
    public static let stitchThreshold = 0.45

    private let engine: DiarizerEngine
    private let configuration: Configuration
    private let logger: Logger
    private var windowCounter = 0

    /// Running set of live speakers, one centroid per stitched provisional key.
    private struct LiveSpeaker {
        let key: String
        var centroid: [Float]
        var appearances: Int
    }
    private var liveSpeakers: [LiveSpeaker] = []
    private var seededModelRevision: String?

    public init(
        engine: DiarizerEngine,
        configuration: Configuration = .init(),
        logger: Logger = Logger(label: LogSubsystem.engine)
    ) {
        self.engine = engine
        self.configuration = configuration
        self.logger = logger
    }

    /// Diarize one window of recent system-stream audio.
    ///
    /// `windowStart` is the window's offset from the start of the recording;
    /// returned spans are recording-absolute. A failure or timeout yields `[]`
    /// (the live pass degrades, never crashes).
    public func diarizeWindow(
        samples: [Float],
        windowStart: Duration
    ) async -> [LiveSpeakerSpan] {
        let started = ContinuousClock.now
        windowCounter += 1

        let engine = self.engine
        let work = Task { try await engine.diarize(samples: samples) }
        let result = await withTaskGroup(of: DiarizationResult?.self) {
            group -> DiarizationResult? in
            group.addTask { try? await work.value }
            group.addTask { [windowTimeout = configuration.windowTimeout] in
                try? await Task.sleep(for: windowTimeout)
                work.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result else {
            logger.warning("live diarization: window produced no usable result")
            return []
        }

        let spans = stitch(result: result, windowStart: windowStart)
        let roundTripMS = Int(((ContinuousClock.now - started).seconds * 1000)
            .rounded())
        let speakerCount = result.speakers.count
        // `.debug`: one line per window (~every 5 s) — a performance
        // observable, not an operational event.
        logger.debug("""
            live diarization: window \(windowCounter) done — \
            \(roundTripMS) ms on ANE, \(speakerCount) speaker(s)
            """)
        return spans
    }

    // MARK: - Stitching

    /// Turn one window's result into stable-keyed, recording-absolute
    /// `LiveSpeakerSpan`s.
    private func stitch(
        result: DiarizationResult, windowStart: Duration
    ) -> [LiveSpeakerSpan] {
        let embeddingByLabel = Dictionary(
            result.embeddings.map { ($0.speaker, $0.vector) },
            uniquingKeysWith: { first, _ in first })

        var keyByRawLabel: [String: String] = [:]
        for (rawLabel, vector) in embeddingByLabel.sorted(by: { $0.key < $1.key }) {
            keyByRawLabel[rawLabel] = stitchKey(for: vector)
        }

        var out: [LiveSpeakerSpan] = []
        for span in result.spans {
            // A raw label with no embedding still gets a key — fall back to a
            // by-name mapping so its span is not dropped.
            let key = keyByRawLabel[span.speaker]
                ?? fallbackKey(forRawLabel: span.speaker)
            out.append(LiveSpeakerSpan(
                provisionalKey: key,
                start: windowStart + span.start,
                end: windowStart + span.end,
                embedding: embeddingByLabel[span.speaker] ?? []))
        }
        return out
    }

    /// Match an embedding to an existing live speaker (cosine ≥ threshold),
    /// refining its centroid; or create a fresh `Them #N`.
    private func stitchKey(for embedding: [Float]) -> String {
        guard !embedding.isEmpty else {
            return fallbackKey(forRawLabel: "noembed")
        }
        var bestIndex = -1
        var bestScore = Self.stitchThreshold
        for (i, speaker) in liveSpeakers.enumerated() {
            let score = Centroid.cosineSimilarity(speaker.centroid, embedding)
            if score >= bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        if bestIndex >= 0 {
            let s = liveSpeakers[bestIndex]
            liveSpeakers[bestIndex].centroid = Centroid.runningMean(
                existing: s.centroid,
                appearanceCount: s.appearances,
                appearance: embedding)
            liveSpeakers[bestIndex].appearances += 1
            return s.key
        }
        let key = Self.provisionalKey(index: liveSpeakers.count)
        liveSpeakers.append(LiveSpeaker(
            key: key, centroid: embedding, appearances: 1))
        return key
    }

    /// Fallback key for a raw label with no embedding — stable per raw label.
    private var fallbackByRaw: [String: String] = [:]
    private func fallbackKey(forRawLabel raw: String) -> String {
        if let existing = fallbackByRaw[raw] { return existing }
        let key = Self.provisionalKey(index: liveSpeakers.count
            + fallbackByRaw.count)
        fallbackByRaw[raw] = key
        return key
    }

    /// The Nth provisional speaker key: `Them`, `Them #2`, `Them #3`, …
    /// (R16 — the `?` suffix is added by `LiveRunner.resolveSystemLabel`).
    public static func provisionalKey(index: Int) -> String {
        index == 0 ? "Them" : "Them #\(index + 1)"
    }

    /// The live-speaker centroids, for a read-only speaker-library lookup
    /// (R18) — keyed by provisional key.
    public func centroids() -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for s in liveSpeakers { out[s.key] = s.centroid }
        return out
    }

    /// The diarization model's content digest. The R18 speaker-library lookup
    /// keys centroid compatibility on this — `bestMatch` skips speakers
    /// recorded under a different revision.
    public func modelRevision() -> String {
        seededModelRevision ?? engine.modelRevision
    }

    /// Test seam: pre-seed the running live-speaker set and the model
    /// revision, so the R18 lookup can be exercised without real models.
    func _seedForTesting(
        speakers: [(key: String, centroid: [Float])],
        modelRevision: String
    ) {
        liveSpeakers = speakers.map {
            LiveSpeaker(key: $0.key, centroid: $0.centroid, appearances: 1)
        }
        seededModelRevision = modelRevision
    }
}
```

Two compile-sensitive points: (a) `engine.modelRevision` is a `let` on an actor — readable without `await` via nonisolated access only if declared `nonisolated let`; if the compiler complains, change `DiarizerEngine.modelRevision` to `public nonisolated let modelRevision: String`. (b) `_seedForTesting` callers (`LiveRunnerLibraryLookupTests`) construct a `LiveDiarizer` — they now need an engine. Give them a lightweight path: make `engine` optional internally is ugly; instead add an internal test initializer:

```swift
/// Test-only: a diarizer with no engine — `diarizeWindow` must not be
/// called; `_seedForTesting` + `centroids()`/`modelRevision()` only.
init(testSeamLogger logger: Logger = Logger(label: LogSubsystem.engine)) {
    self.engine = nil
    self.configuration = .init()
    self.logger = logger
}
```

…which requires `private let engine: DiarizerEngine?` and a `guard let engine` returning `[]` at the top of `diarizeWindow`. Use the optional-engine form in the final code (adjust `modelRevision()` to `seededModelRevision ?? engine?.modelRevision ?? ""` — an empty revision matches nothing in a populated library, the same safe degradation as before).

- [ ] **Step 5: Rewire `StreamingPipeline`**

In `Configuration` (lines 44-69): replace `public let liveDiarizerConfig: LiveDiarizer.Configuration?` with `public let liveDiarizerEngine: DiarizerEngine?` (doc: "`nil` → no live diarization (system speakers stay the generic `Them?`)"), and update the init parameter accordingly. In `run` (lines 142-183): replace the subprocess block with

```swift
// --- live diarization (in-process, optional) -------------------------
var liveDiarizer: LiveDiarizer?
if let engine = configuration.liveDiarizerEngine {
    liveDiarizer = LiveDiarizer(engine: engine, logger: logger)
}
```

and delete both `await liveDiarizer?.stop()` calls (no subprocess to stop; the `defer`-equivalent error path keeps only `await writer.finish()`).

- [ ] **Step 6: Rewire `Sources/pulsartrace-engine/main.swift`**

Replace lines 164-170 with:

```swift
// --- live diarization engine (resident, ANE — D40) ------------------
// Loaded next to Parakeet so the model download happens before audio
// starts. A load failure degrades to generic `Them` labels, never
// blocks the live pass.
var diarizerEngine: DiarizerEngine?
if !args.contains("--no-live-diarization") {
    do {
        diarizerEngine = try await DiarizerEngine.load(
            cacheRoot: AppPaths.standard.modelsCacheDirectory,
            events: lifecycle.events,
            logger: Logger(label: LogSubsystem.engine))
    } catch {
        Logger(label: LogSubsystem.engine).error(
            "live diarization unavailable — continuing with generic Them "
                + "labels: \(PathRedactor.redactHome("\(error)"))")
    }
}
```

Pass `liveDiarizerEngine: diarizerEngine` in the `StreamingPipeline.Configuration` init (line 209). Delete `liveDiarizerConfig()` (lines 232-267) and `dotEnv(repoRoot:)` (lines 269-291).

- [ ] **Step 7: Fix the `_seedForTesting` call sites and remaining fallout**

```bash
swift build --build-tests
```

Update `LiveRunnerLibraryLookupTests` (and any other `_seedForTesting` user) to construct via the test-seam initializer. Update any test constructing `StreamingPipeline.Configuration(liveDiarizerConfig:)` to pass `liveDiarizerEngine: nil` (or drop the argument — it defaults if you give it a default of `nil` in the init; do give it a default).

- [ ] **Step 8: Run the suites**

```bash
swift test --filter UnitTests
swift test --filter LiveRunner
swift test --filter Streaming
swift test --filter DiarizationE2E
```

Expected: PASS.

- [ ] **Step 9: Delete the transitional `redactingPaths` extension from `Diarizer.swift`**

```bash
grep -rn "redactingPaths" Sources/ Tests/
```

If the only remaining hits are the extension itself, delete it; otherwise keep and note why. Build to confirm.

- [ ] **Step 10: Commit**

```bash
git add -A Sources/ Tests/
git commit -m "feat(live)!: live diarization runs in-process on the ANE; subprocess + scratch WAVs retired"
```

---

### Task 6: Speaker library schema v3 — column rename + archive-and-reset migration

WeSpeaker centroids and pyannote centroids are mutually meaningless. v3 renames `pyannote_model_revision` → `model_revision` (the field was never pyannote-specific in meaning — it is the centroid-compatibility key) and, on first open of a pre-v3 database, archives the whole file and starts fresh (Decision 2).

**Files:**
- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerLibrary.swift` (schema lines 200-281, SQL at lines ~958, ~986)
- Modify: `Sources/PulsarTraceEngine/SpeakerLibrary/Speaker.swift` (property rename, lines 15-20, 40-62)
- Test: `Tests/UnitTests/SpeakerLibraryUnitTests.swift` (+ a new migration test)

- [ ] **Step 1: Inventory the rename ripple**

```bash
grep -rn "pyannoteModelRevision\|pyannote_model_revision" Sources/ Tests/ --include="*.swift"
```

Every hit gets the mechanical rename `pyannoteModelRevision` → `modelRevision` / `pyannote_model_revision` → `model_revision` (known: `Speaker.swift`, `SpeakerLibrary.swift` SQL + row mapping, `SpeakerReconciler.swift` doc comment, `LiveRunner` if it names the property, unit/pipeline tests).

- [ ] **Step 2: Write the failing migration test**

Append to `Tests/UnitTests/SpeakerLibraryUnitTests.swift` (match the suite's existing temp-dir/fixture conventions):

```swift
@Test func preV3DatabaseIsArchivedAndReset() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appendingPathComponent("speakers.sqlite")

    // Build a v2-shaped database by hand: old column name, user_version 2,
    // one speaker row.
    let old = try SQLiteDatabase(url: dbURL)
    try old.exec("""
        CREATE TABLE speakers (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, centroid BLOB NOT NULL,
            pyannote_model_revision TEXT NOT NULL,
            appearance_count INTEGER NOT NULL DEFAULT 0,
            last_seen TEXT NOT NULL, sample_audio_path TEXT,
            created_at TEXT NOT NULL, deleted_at TEXT, delisted_at TEXT
        );
        CREATE TABLE appearances (
            speaker_id TEXT NOT NULL REFERENCES speakers(id) ON DELETE RESTRICT,
            recording_id TEXT NOT NULL, recording_folder_name TEXT NOT NULL,
            observed_at TEXT NOT NULL, origin_speaker_id TEXT,
            PRIMARY KEY (speaker_id, recording_id)
        );
        INSERT INTO speakers VALUES ('spk_OLD', 'Steve', x'00000000',
            'deadbeef', 1, '2026-01-01T00:00:00Z', NULL,
            '2026-01-01T00:00:00Z', NULL, NULL);
        """)
    try old.setUserVersion(2)
    old.close()   // match SQLiteDatabase's actual close/deinit API

    let library = try await SpeakerLibrary(databaseURL: dbURL, events: nil)
    // Fresh library: the pyannote-space speaker is gone…
    #expect(try await library.liveSpeakers().isEmpty)
    // …and the old data is archived next to the database.
    let archive = dbURL.deletingLastPathComponent()
        .appendingPathComponent("speakers.sqlite.pre-v3.bak")
    #expect(FileManager.default.fileExists(atPath: archive.path))
}
```

(Adapt the `SQLiteDatabase` open/exec/close calls to its real API in `Sources/PulsarTraceEngine/SpeakerLibrary/SQLiteDatabase.swift`, and the `SpeakerLibrary` init signature to the one `OfflineRefiner.swift:96` uses.)

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter SpeakerLibrary`
Expected: the new test FAILS (old column kept / no archive); existing tests still pass.

- [ ] **Step 4: Implement v3 in `SpeakerLibrary.swift`**

1. `private static let schemaVersion: Int32 = 3`, with history note:

```swift
/// - v3: D40 — diarization moved to FluidAudio/WeSpeaker embeddings.
///   `pyannote_model_revision` → `model_revision`, and a pre-v3 database
///   is archived to `speakers.sqlite.pre-v3.bak` and reset: pyannote-space
///   centroids can never match WeSpeaker embeddings, so carrying the rows
///   forward would only accumulate permanently-dead entries.
```

2. In the base `CREATE TABLE` DDL: `pyannote_model_revision TEXT NOT NULL` → `model_revision TEXT NOT NULL` (and the per-row comment above it: "…so a model upgrade (Open Q #3 / D40) can coexist…").

3. In `migrate(_:)`, **before** the DDL transaction, add the archive-and-reset step:

```swift
// v2 → v3 (D40): the embedding space changed (pyannote → WeSpeaker), so
// every stored centroid is permanently unmatchable. Archive the whole
// database file and start fresh rather than carrying dead rows.
let preV3Columns = try db.query("PRAGMA table_info(speakers);")
    .compactMap { $0.string(1) }
if preV3Columns.contains("pyannote_model_revision") {
    let archiveURL = db.url.deletingLastPathComponent()
        .appendingPathComponent("speakers.sqlite.pre-v3.bak")
    try? FileManager.default.removeItem(at: archiveURL)
    try db.exec("VACUUM INTO '\(archiveURL.path.replacingOccurrences(of: "'", with: "''"))';")
    try db.exec("""
        DROP TABLE IF EXISTS appearances;
        DROP TABLE IF EXISTS speakers;
        """)
}
```

(`PRAGMA table_info` on a missing table returns no rows, so fresh databases skip this. If `SQLiteDatabase` does not expose its `url`, add a `let url: URL` stored property to it — it receives the URL at init. `VACUUM INTO` cannot run inside a transaction — keep this block before `db.transaction { … }`.)

4. The old v1→v2 conditional `delisted_at` ALTER block can be deleted outright: any database old enough to need it is also pre-v3 and was just reset. Keep the `delisted_at` index creation (it's in the base DDL path).

5. Rename the column in every SQL string (`selectSpeakers` at ~line 958, `insert` at ~line 986, the centroid UPDATE) and the `Speaker` row-mapping code.

- [ ] **Step 5: Rename the Swift property**

In `Speaker.swift`: `public var pyannoteModelRevision: String` → `public var modelRevision: String` (update the doc comment: "Diarization-model revision (content digest, D40) the centroid was built under…"). Apply the Step 1 grep list mechanically across Sources and Tests.

- [ ] **Step 6: Run the suites**

```bash
swift test --filter Speaker
swift test --filter UnitTests
swift test --filter Refinement
```

Expected: PASS, including the new migration test.

- [ ] **Step 7: Commit**

```bash
git add Sources/PulsarTraceEngine/SpeakerLibrary/ Tests/ Sources/
git commit -m "feat(speakers)!: library schema v3 — model_revision rename; pre-v3 pyannote-space library archived and reset"
```

---

### Task 7: Threshold calibration for the WeSpeaker space

The two cosine-similarity thresholds were tuned for pyannote's space and are now wrong by an unknown amount. This task measures the actual same-speaker vs cross-speaker similarities on the committed fixtures and pins the constants.

**Files:**
- Test: calibration suite in `Tests/PipelineTests/DiarizationE2ETests.swift`
- Modify (values only): `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerLibrary.swift:25` (`defaultMatchThreshold`), `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift` (`stitchThreshold`)

- [ ] **Step 1: Write the calibration test**

Append to `Tests/PipelineTests/DiarizationE2ETests.swift`:

```swift
/// Pins the WeSpeaker-space similarity thresholds (D40). If this fails after
/// a model bump, read the printed similarities and re-pin the constants:
/// both thresholds must sit between the worst same-speaker similarity and the
/// best cross-speaker similarity, with margin on both sides.
@Suite("DiarizationE2E threshold calibration", .serialized)
struct DiarizationE2ECalibrationTests {

    private func fixtureSamples(_ name: String) async throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio/\(name).wav")
        let source = FixturePlaybackSource(file: url, realtime: false)
        return try await OfflineTranscriptionPipeline(
            logger: Logger(label: "test")).accumulate(source)
    }

    @Test func thresholdsSeparateSameFromCross() async throws {
        let engine = try await DiarizerTestEngine.shared()

        // Same speaker: the two halves of a 30 s single-speaker clip must
        // produce embeddings that match.
        let solo = try await fixtureSamples("single-speaker-30s")
        let firstHalf = try await engine.diarize(
            samples: Array(solo[..<(solo.count / 2)]))
        let secondHalf = try await engine.diarize(
            samples: Array(solo[(solo.count / 2)...]))
        let a = try #require(firstHalf.embeddings.first?.vector)
        let b = try #require(secondHalf.embeddings.first?.vector)
        let same = Centroid.cosineSimilarity(a, b)

        // Different speakers: the two clusters of the alternating clip.
        let duo = try await engine.diarize(
            samples: try await fixtureSamples("two-speakers-alternating"))
        try #require(duo.embeddings.count == 2)
        let cross = Centroid.cosineSimilarity(
            duo.embeddings[0].vector, duo.embeddings[1].vector)

        print("calibration: same-speaker=\(same) cross-speaker=\(cross) "
            + "library-threshold=\(SpeakerLibrary.defaultMatchThreshold) "
            + "stitch-threshold=\(LiveDiarizer.stitchThreshold)")

        #expect(same - cross > 0.15)   // the space separates at all
        #expect(same > SpeakerLibrary.defaultMatchThreshold)
        #expect(cross < SpeakerLibrary.defaultMatchThreshold)
        #expect(same > LiveDiarizer.stitchThreshold)
        #expect(cross < LiveDiarizer.stitchThreshold)
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter DiarizationE2ECalibration`

Two outcomes:
- **PASS** with the seeded 0.45 values → go to Step 3.
- **FAIL** → read the printed `same`/`cross` values and set both constants to the midpoint `(same + cross) / 2`, rounded to two decimals; if `same - cross ≤ 0.15`, **stop and escalate to the user** — the fixtures may be too short for stable WeSpeaker embeddings and the threshold decision needs human judgment. Re-run until PASS.

- [ ] **Step 3: Pin the values + document**

Update `SpeakerLibrary.defaultMatchThreshold` (line 25) and `LiveDiarizer.stitchThreshold` to the calibrated values, each with a comment:

```swift
/// Calibrated for the WeSpeaker embedding space (D40): on the committed
/// fixtures, same-speaker similarity measured ~<SAME>, cross-speaker
/// ~<CROSS> (see the DiarizationE2E calibration suite).
```

(Fill `<SAME>`/`<CROSS>` with the measured numbers — they also go into the D40 decision text in Task 10.)

- [ ] **Step 4: Re-run the dependent suites**

```bash
swift test --filter Speaker
swift test --filter DiarizationE2E
```

Expected: PASS (reconciler/library tests use synthetic vectors with similarity ~1.0/~0.0, far from any sane threshold — but verify).

- [ ] **Step 5: Commit**

```bash
git add Sources/ Tests/
git commit -m "feat(diarization): calibrate matching thresholds for the WeSpeaker space"
```

---

### Task 8: Doctor — replace the Python-runtime check with a model-cache check

**Files:**
- Modify: `Sources/PulsarTraceEngine/Support/Doctor.swift:106-118`
- Modify: `Sources/pulsartrace/DoctorCommand.swift:55-57, 120-135`
- Test: the existing doctor unit tests (find via `grep -rn "pythonRuntimeCheck" Tests/`)

- [ ] **Step 1: Update the failing tests first**

Rename/repoint the `pythonRuntimeCheck` unit tests to the new check:

```swift
@Test func diarizerModelsCachedIsOK() {
    let check = EnvironmentDoctor.diarizerModelsCheck(cached: true)
    #expect(check.status == .ok)
}

@Test func diarizerModelsMissingIsInformationalWarn() {
    let check = EnvironmentDoctor.diarizerModelsCheck(cached: false)
    #expect(check.status == .warn)
    #expect(check.detail.contains("first"))
}
```

Run: `swift test --filter Doctor` → FAIL (no such function).

- [ ] **Step 2: Implement in `Doctor.swift` (replacing lines 106-118)**

```swift
/// The diarization models (FluidAudio CoreML bundles, D40). Absence is not
/// an error — they download automatically from huggingface.co on the first
/// recording or refine — but the user should know a download is coming.
public static func diarizerModelsCheck(cached: Bool) -> DoctorCheck {
    if cached {
        return DoctorCheck(
            name: "Diarization models", status: .ok,
            detail: "CoreML bundles cached")
    }
    return DoctorCheck(
        name: "Diarization models", status: .warn,
        detail: "not yet downloaded — the first recording or refine fetches "
            + "them from huggingface.co automatically")
}
```

- [ ] **Step 3: Rewire `DoctorCommand.swift`**

Replace lines 55-57 with:

```swift
// --- diarization models (ANE, D40) ----------------------------------
let diarizerModelDir = AppPaths.standard.modelsCacheDirectory
    .appendingPathComponent(DiarizerEngine.repoFolderName, isDirectory: true)
let diarizerCached = ["Segmentation.mlmodelc", "FBank.mlmodelc",
                      "Embedding.mlmodelc", "PldaRho.mlmodelc"]
    .allSatisfy {
        FileManager.default.fileExists(
            atPath: diarizerModelDir.appendingPathComponent($0).path)
    }
checks.append(EnvironmentDoctor.diarizerModelsCheck(cached: diarizerCached))
```

Delete `venvPythonURL()` (lines 120-135) and any now-unused imports.

- [ ] **Step 4: Run + commit**

Run: `swift test --filter Doctor` and `swift test --filter UnitTests` → PASS.

```bash
git add Sources/ Tests/
git commit -m "feat(doctor): diarization check is now the CoreML model cache, not a python venv"
```

---

### Task 9: Delete the Python tree; scrub the dev-environment references

**Files:**
- Delete: `python/` (whole tree)
- Modify: `README.md`, `CLAUDE.md`, `.env.example` if present

- [ ] **Step 1: Confirm nothing in Sources/Tests references the sidecar anymore**

```bash
grep -rn "pulsartrace_ai\|pulsartrace-ai\|venv\|PULSARTRACE_VENV_PYTHON\|HF_TOKEN\|HF_HOME\|PYANNOTE_METRICS" Sources/ Tests/ --include="*.swift"
```

Expected: zero hits (any hit is unfinished work from Tasks 4-5/8 — fix it first). Then:

```bash
git rm -r python/
```

(`python/pulsartrace-ai/.venv/` is untracked; remove the leftover directory with `rm -rf python/` afterwards if `git rm` leaves it.)

- [ ] **Step 2: Update `README.md`**

From the grep at lines 5, 45-66, 246-296, 313, 323:
- Line 5: "...and speaker diarization (pyannote)" → "...and speaker diarization (pyannote community-1 on CoreML)".
- Lines 45-52: drop `python@3.12` from the Homebrew line; **delete** the entire Hugging Face account/token prerequisite (the FluidAudio model repo is public); update the disk estimate ("pyannote ~1 GB" → "diarization CoreML bundles ~a few hundred MB" — use the real size observed in Task 3's download).
- Lines 62-66: delete the `./python/build-venv.sh` and `.env`/`HF_TOKEN` setup steps.
- Line 246 (architecture diagram) + 255-256: pyannote-subprocess boxes/bullets → "FluidAudio offline diarization (CoreML/ANE) — speaker spans + embeddings in-process"; "voices matched by cosine similarity of WeSpeaker embeddings".
- Lines 274-275: delete the `python/…` rows from the repo-layout table.
- Lines 290-296: drop the pytest line; reword "real ANE ASR + pyannote" → "real ANE models".
- Line 313: "...the transcription models (Parakeet + WhisperKit CoreML bundles) and the pyannote model" → "...the transcription and diarization CoreML bundles".
- Line 323: keep the FluidAudio + pyannote.audio credits; replace the pyannote *runtime* framing with model lineage: "the diarization models are FluidInference's CoreML conversion of `pyannote/speaker-diarization-community-1`"; drop PyTorch from the credits (no longer shipped).

- [ ] **Step 3: Update `CLAUDE.md`**

In the narrow-filter list: `- \`swift test --filter DiarizationE2E\`` gets the note "— FluidAudio offline diarization (one-time model download)". Remove any other venv/HF_TOKEN mentions if present.

- [ ] **Step 4: Build + run the fast suite, commit**

```bash
swift build
swift test --filter UnitTests
git add -A
git commit -m "chore!: delete the python sidecar — diarization is fully in-process (D40)"
```

---

### Task 10: Decision record, plan/status docs, events schema, changelog

**Files:**
- Modify: `project-docs/DECISIONS.md` (append D40), `project-docs/PLAN.md`, `docs/events-schema.md:132`, `CHANGELOG.md`

- [ ] **Step 1: Write D40 in `project-docs/DECISIONS.md`**

Append after D39, following the house format (decision, alternatives, consequences). Content to cover — written out, not paraphrased, when executing:

- Diarization (both passes) moves from the Python pyannote sidecar to FluidAudio 0.15.2's `OfflineDiarizerManager` (pyannote community-1 ported to CoreML, WeSpeaker embeddings, VBx clustering, ANE). This completes the D39 deferral and supersedes D9 (one-shot subprocess), D19 (windowed-pyannote subprocess), and the pyannote-specific halves of D10/D12 (HF_HOME redirect, telemetry kill-switch — both moot: no Python process exists, and the only network call is the public-repo model download already governed by the D39 pattern).
- The live pass keeps the 10 s/5 s windowed design and stitching; only the per-window inference moved in-process. R29 (one embedding space) now spans live + offline + library by construction.
- `modelRevision` is the `DirectoryDigest` SHA-256 of the model directory (content-addressed; replaces the HF commit SHA; same Open-Question-#3 scoping semantics).
- Speaker library schema v3: column rename + archive-and-reset of pre-v3 (pyannote-space) libraries — record the wipe rationale and the `speakers.sqlite.pre-v3.bak` archive path.
- Calibrated thresholds with the measured same/cross similarities from Task 7.
- `metadata.json` schema v2 (`diarization_model`).
- PRD §17's "pyannote stays in Python" is superseded by this decision (mirroring how D39 superseded the whisper.cpp sections).

- [ ] **Step 2: Update `project-docs/PLAN.md`**

Find the diarization/ANE-migration line items (grep `pyannote\|diarization` in PLAN.md) and mark the migration done / re-point descriptions at D40.

- [ ] **Step 3: Update `docs/events-schema.md:132`**

`model_name` examples: `e.g. \`parakeet-v3\`, \`large-v3-turbo\`` → add `\`speaker-diarization-coreml\``.

- [ ] **Step 4: Update `CHANGELOG.md`**

Add under the unreleased heading (match the file's existing format):

```markdown
- Speaker diarization now runs fully in-process on the Apple Neural Engine
  (FluidAudio's CoreML port of pyannote community-1) — the embedded Python
  environment, Hugging Face token, and `python/build-venv.sh` setup step are
  gone. Existing speaker libraries are archived and reset (embeddings moved
  to a new vector space); speakers re-appear as `Unknown #N` on next refine.
  `metadata.json` is now schema v2 (`diarization_model`).
```

- [ ] **Step 5: Commit**

```bash
git add project-docs/ docs/ CHANGELOG.md
git commit -m "docs: D40 — diarization moves to the ANE; pyannote sidecar decisions superseded"
```

---

### Task 11: Full verification + finish

- [ ] **Step 1: Run every narrow filter from CLAUDE.md**

```bash
swift test --filter UnitTests
swift test --filter Refinement
swift test --filter IPC
swift test --filter RecordOrchestrator
swift test --filter LiveRunner
swift test --filter Streaming
swift test --filter Parakeet
swift test --filter WhisperKitRefine
swift test --filter FluidVAD
swift test --filter Speaker
swift test --filter DiarizationE2E
swift test --filter Source
swift test --filter Lifecycle
swift test --filter FinalMarkdownRewriter
```

Expected: every filter PASS. Any failure — even in a suite this plan didn't touch — blocks completion (no-failing-tests rule).

- [ ] **Step 2: Manual smoke (real models, real WAV)**

```bash
.build/debug/pulsartrace refine Tests/Fixtures/audio/two-speakers-alternating.wav
```

Inspect the output folder: `final.md` has two distinct speaker labels (`Unknown #1`/`Unknown #2` on a fresh library); `metadata.json` has `schema_version: 2` and a `diarization_model` block with a 64-hex `revision`.

- [ ] **Step 3: Run the doc-sync skill**

Invoke `pulsartrace-doc-sync` to sweep `docs/`, README, CHANGELOG for anything Tasks 9-10 missed (e.g. `docs/qa/`, `docs/release-smoke-test.md` mention pyannote/venv — fix per the skill's standards).

- [ ] **Step 4: Finish the branch**

Invoke `pulsartrace-finishing-a-development-branch` to choose merge/PR handling.

---

## Self-review notes

- **Spec coverage:** scope decision (both passes) → Tasks 4-5; library clean break → Task 6; model identity → Task 3; thresholds → Task 7; metadata/contract → Task 2; python deletion → Task 9; docs/decisions → Tasks 10-11. R17 (system-stream-only) is structural in the rewritten `Diarizer`; R29 by shared engine; R18 via digest revision + `_seedForTesting` kept; D-Q7 pause-retry via `.cancelled` case name kept so `ResumableRefiner.swift:319-320` compiles untouched.
- **Known judgment calls left to the executor (all flagged in-task):** exact `OfflineDiarizationError.noSpeechDetected` pattern-match shape (Task 3 Step 5), `SQLiteDatabase` API names in the migration test (Task 6 Step 2), `nonisolated let modelRevision` if the compiler demands it (Task 5 Step 4), real model download size for the README (Task 9 Step 2), measured threshold values (Task 7).
- **Deliberately not done:** no shared-engine optimization across refine-queue jobs (per-job model load ~1-3 s, models disk-cached — YAGNI); no re-enrollment of existing speakers (Decision 2); no Sortformer/streaming diarizer (Decision 1); `pyannote` JSON fixtures kept as frozen merge-test data, not regenerated.
