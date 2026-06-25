> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 12: Live cutover — Parakeet only, no live model knob

After this task the live pass runs **only** Parakeet v3. The engine's `--model` flag, `RecordPlan.make`'s `modelName:` parameter, and `record`'s `--model` flag are gone. The legacy whisper sources still exist untouched (refinement still uses them until task 13); they are deleted in task 16.

**The capture `--model` question, resolved (verified in this repo):** `pulsartrace-capture` parses `--model` into `modelLive` (`Sources/pulsartrace-capture/main.swift:38`), which flows into `DeviceCaptureSource.Configuration.modelLive` and from there into the **public events schema**: `RecordingStartedEvent.modelLive` (`Sources/PulsarTraceEngine/Events/Event.swift:325`, JSON key `model_live` in `recording_started`, emitted at `DeviceCaptureSource.startCapture`). Removing an event field is a breaking public-API change, so the field stays. Resolution: `RecordPlan` keeps passing a literal `"--model", "parakeet-v3"` **to capture only** (with a comment), so the event reports the only live model there is; capture's own code is untouched. The engine arguments lose `--model` entirely.

**Files:**
- Create: `Tests/PipelineTests/ParakeetTestEngine.swift`
- Modify: `Sources/PulsarTraceEngine/Refinement/RecordPlan.swift`
- Modify: `Sources/pulsartrace-engine/main.swift` (live(), lines ~131–256 + usage strings)
- Modify: `Sources/pulsartrace/RecordCommand.swift` (drop `--model`)
- Modify: `Sources/PulsarTraceMenuBar/RecordingViewModel.swift:254-260` (RecordPlan.make call)
- Modify: `Tests/UnitTests/RecordPlanTests.swift`
- Modify: `Tests/PipelineTests/ParakeetTranscriberTests.swift` (use the shared engine)
- Modify: `Tests/PipelineTests/StreamingPipelineTests.swift` (migrate to Parakeet + keyword assertions)
- Delete: `Tests/PipelineTests/__Snapshots__/StreamingPipelineTests/liveMDSnapshot.1.txt`

- [ ] **Step 1: Update RecordPlanTests first (failing)**

In `Tests/UnitTests/RecordPlanTests.swift`, delete the `modelName:` argument from every `RecordPlan.make(...)` call (grep: `grep -n "modelName" Tests/UnitTests/RecordPlanTests.swift`), change the two model assertions in `systemAndMic`, and add the event-field test:

In `systemAndMic`, replace `#expect(value(after: "--model", in: plan.engineArguments) == "base")` with:

```swift
        // The live pass has exactly one backend (D39): the engine takes no
        // model flag; capture still reports the fixed name in
        // `recording_started.model_live`.
        #expect(!plan.engineArguments.contains("--model"))
        #expect(value(after: "--model", in: plan.captureArguments) == "parakeet-v3")
```

Append the new test to the suite:

```swift
    @Test("capture carries the fixed live model name for the recording_started event")
    func captureCarriesTheFixedLiveModelName() {
        let plan = RecordPlan.make(
            outputFolder: folder, paths: paths,
            micDeviceID: nil, systemAudioEnabled: true)
        #expect(value(after: "--model", in: plan.captureArguments) == "parakeet-v3")
        #expect(!plan.engineArguments.contains("--model"))
    }
```

Run: `swift test --filter RecordPlan` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md — same for every build/test step below)
Expected: FAIL — `extra argument 'modelName' in call` / missing-argument compile errors.

- [ ] **Step 2: Drop the parameter from RecordPlan**

In `Sources/PulsarTraceEngine/Refinement/RecordPlan.swift`, delete the `modelName:` parameter and its doc line; the new signature and the two argv blocks:

```swift
    public static func make(
        outputFolder: URL,
        paths: AppPaths,
        micDeviceID: String?,
        systemAudioEnabled: Bool,
        allowedLanguages: [String] = []
    ) -> RecordPlan {
```

```swift
        var captureArgs = [
            "--recording-id", recordingId,
            "--out", outputFolder.path,
            "--system-socket", systemSocket.path,
            "--mic-socket", micSocket.path,
            // The live pass has exactly one backend (D39). Capture still
            // takes `--model` because the value feeds the public
            // `recording_started` event's `model_live` field
            // (RecordingStartedEvent) — removing an event field is a
            // breaking public-API change. Fixed to the only live model.
            "--model", "parakeet-v3",
        ]
```

and in `engineArgs`, delete the `"--model", modelName,` line (the engine has no model flag any more). Everything else is unchanged.

- [ ] **Step 3: Cut the engine's live() over to Parakeet**

In `Sources/pulsartrace-engine/main.swift`:

1. Replace the whole block from `// --- whisper model (resident) ---` (line ~181) through the `micTranscriber = nil` else-branch (line ~256) — i.e. the `--model` parsing, `ModelStore`, `whisperHostConfig`, `SerializingHostProxy`, `whisperConfig`, both `RemoteWindowTranscriber` constructions, and all their comments — with:

```swift
        // --- live transcriber (resident, ANE) --------------------------------
        // Parakeet v3 via FluidAudio (D39): in-process CoreML — no subprocess,
        // no Metal, no flock, and no live model knob. Both streams share one
        // resident engine; the actor serializes decodes (the in-process
        // analogue of the old SerializingHostProxy). First launch downloads
        // ~0.5 GB from huggingface.co. A wedged window decode is bounded by
        // ParakeetWindowTranscriber's 30 s deadline — the window is skipped
        // and the post-pass recovers the audio.
        //
        // Cache root: ModelStore.defaultCacheDirectory() until task 16 of
        // docs/specs/2026-06-12-ane-transcription-pipeline/ replaces it with
        // AppPaths.modelsCacheDirectory and deletes ModelStore.
        let parakeet = try await ParakeetEngine.load(
            cacheRoot: ModelStore.defaultCacheDirectory(),
            events: lifecycle.events,
            logger: Logger(label: LogSubsystem.engine))
        let transcriber: any WindowTranscribing =
            ParakeetWindowTranscriber(engine: parakeet)
        let micTranscriber: (any WindowTranscribing)? = micSource != nil
            ? ParakeetWindowTranscriber(engine: parakeet)
            : nil
```

2. Update the `--live` usage string (line ~159): delete `[--model base|large-v3]` from it.
3. Update the stale `--mic-fixture` comment (lines ~132–136): replace the sentence about "dual-stream contention on the shared SerializingHostProxy … one whisper subprocess" with:

```swift
            // `--mic-fixture <path>` pairs a second realtime fixture as the
            // mic stream so a one-WAV repro can exercise the dual-stream
            // contention on the single shared ParakeetEngine actor — pass
            // the same WAV to drive 2× decode load on one resident model.
```

(The `--transcribe` mode and its `--model` flag are untouched here — that whole mode is deleted with `WhisperTranscriber` in task 16.)

- [ ] **Step 4: Drop `--model` from RecordCommand**

In `Sources/pulsartrace/RecordCommand.swift`:

1. `Options`: delete `let modelName: String`.
2. `parse`: delete `var modelName = "base"`, the `case "--model":` arm, and `modelName:` from the `Options(...)` constructor.
3. Delete the model-validation guard (lines ~55–59, `guard ModelCatalog.model(named: options.modelName) != nil else { … }`).
4. The `RecordPlan.make` call (line ~96) loses `modelName: options.modelName`.
5. The post-record refine invocation (line ~153) becomes:

```swift
        let refineCode = await RefineCommand.run(
            // Interim: refine still runs on whisper.cpp until task 14 adds
            // `--refine-model`; "base" keeps D24's no-surprise-download
            // default. Task 14 replaces this with options.refineModelName.
            [outputFolder.path, "--model", "base"], events: events)
```

6. Update the doc comment at the top (delete the `--model` paragraph; the live pass is fixed to Parakeet, the refine model becomes a flag in task 14) and the usage string:

```swift
    static let usage =
        "usage: pulsartrace record [--output PATH] [--duration MIN] "
        + "[--mic INDEX] [--no-system-audio] [--list-mics]"
```

- [ ] **Step 5: Update the remaining `RecordPlan.make` call site**

`Sources/PulsarTraceMenuBar/RecordingViewModel.swift` line ~254: delete the `modelName: settings.liveModelName,` line:

```swift
        let plan = RecordPlan.make(
            outputFolder: outputFolder,
            paths: paths,
            micDeviceID: settings.selectedMicDeviceID,
            systemAudioEnabled: settings.systemAudioEnabled,
            allowedLanguages: settings.allowedLanguages)
```

(`settings.liveModelName` itself survives, unused, until task 15 removes it.) Then verify there are no other call sites:

Run: `grep -rn "RecordPlan.make" Sources/ Tests/`
Expected: only `RecordPlan.swift` (definition), `RecordCommand.swift`, `RecordingViewModel.swift`, `RecordPlanTests.swift` — all already updated. Fix anything else the grep or compiler finds the same way (delete the `modelName:` argument).

- [ ] **Step 6: Build + RecordPlan/unit tests green**

Run: `swift build`
Expected: compiles — the compiler is the rename checklist.
Run: `swift test --filter RecordPlan`
Expected: PASS.
Run: `swift test --filter UnitTests`
Expected: PASS.

- [ ] **Step 7: Add the shared test engine and use it in ParakeetTranscriberTests**

Create `Tests/PipelineTests/ParakeetTestEngine.swift`:

```swift
import Foundation
import Logging
@testable import PulsarTraceEngine

/// One resident Parakeet engine per test process, shared by every
/// PipelineTests suite that needs a real live decode (ParakeetTranscriber,
/// StreamingPipeline, and — after task 16 — IPCTwoDaemon and
/// LiveRunnerResilience). Memoizing the Task (not the engine) makes a
/// second concurrent first-caller await the in-flight load instead of
/// racing a duplicate ~0.5 GB download — the same pattern the old
/// WhisperTestGate used for ggml models.
enum ParakeetTestEngine {
    private static let task = Task<ParakeetEngine, Error> {
        try await ParakeetEngine.load(
            cacheRoot: ModelStore.defaultCacheDirectory(),
            events: nil,
            logger: Logger(label: "test.parakeet"))
    }

    static func shared() async throws -> ParakeetEngine {
        try await task.value
    }
}
```

In `Tests/PipelineTests/ParakeetTranscriberTests.swift`, delete the private `engineTask` static and replace every `try await Self.engineTask.value` with `try await ParakeetTestEngine.shared()` (6 occurrences across tasks 06–07's tests).

- [ ] **Step 8: Migrate StreamingPipelineTests to Parakeet + keyword assertions**

`Tests/PipelineTests/StreamingPipelineTests.swift` currently builds real whisper transcribers (`WhisperTestTranscriber.make`) inside `WhisperTestGate.run` and snapshot-asserts live.md. Migrate it; the `liveSinkDropsMicEcho` test decodes no audio — **leave it unchanged**.

1. Drop `import SnapshotTesting` (no snapshot remains in this file).
2. Delete the `baseModelURL()` helper.
3. Update the suite doc comment (the paragraphs about whisper CPU backend/D15, the snapshot, and the D8 single-context rationale):

```swift
/// Pipeline coverage of the live pass (R10, R12, R14, R16, R35a, R36, R37).
///
/// Drives a real fixture WAV through `FixturePlaybackSource` →
/// `StreamingTranscriber` (sliding-window Parakeet + LocalAgreement-2) →
/// append-only `live.md`, with no live diarization (the windowed-pyannote
/// subprocess is exercised by the manual smoke test — these tests stay fast
/// and device/network-free after the one-time model download).
///
/// Determinism: Parakeet's greedy TDT decode is deterministic, so structure
/// and keyword assertions are stable. Transcript text is asserted via
/// fixture keywords (D39 supersedes the old whisper snapshot strategy —
/// keywords survive small wording drift between decoder versions; the
/// retired snapshot lives in git history).
///
/// `.serialized`: one resident ANE model serves the whole process
/// (`ParakeetTestEngine`); serializing keeps decode interleaving sane.
```

4. Replace `liveRunProducesProvisionalLiveMD`'s body:

```swift
    @Test("fast-mode live run grows an append-only live.md with provisional labels")
    func liveRunProducesProvisionalLiveMD() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let transcriber = ParakeetWindowTranscriber(engine: engine)
        let pipeline = StreamingPipeline()
        // Fast mode keeps the suite quick; the realtime/lag test below
        // covers R10 pacing.
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("two-speakers-alternating.wav"),
            realtime: false)
        let output = try await pipeline.run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_two-speakers-alternating",
                liveDiarizerConfig: nil),
            systemTranscriber: transcriber,
            systemSource: source,
            library: nil)

        // R35a/R37: file created with marker + header.
        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "<!-- pulsartrace:live -->")
        #expect(lines[1].hasPrefix("## Transcript — "))

        // R14/R16: system speakers labelled `Them …?`.
        #expect(text.contains("Them?:"))
        #expect(!text.contains("Speaker_"))   // no offline-style labels
        #expect(output.utteranceLines > 0)

        // Parakeet has no language-ID head — the live pass reports the
        // "no information" contract value (the refine pass detects/pins).
        #expect(output.language == "unknown")
    }
```

5. Replace the `liveMDSnapshot` test wholesale with the keyword/structure test. The keywords were extracted from the retired snapshot `Tests/PipelineTests/__Snapshots__/StreamingPipelineTests/liveMDSnapshot.1.txt` ("…coffee shop this morning… near the bookstore… the barista asked me… we finished the data ingestion piece… the next step is the transformation layer."):

```swift
    @Test("live.md carries the fixture's distinctive words with monotonic timestamps")
    func liveMDContentAndStructure() async throws {
        let engine = try await ParakeetTestEngine.shared()
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let transcriber = ParakeetWindowTranscriber(engine: engine)
        let pipeline = StreamingPipeline()
        let source = FixturePlaybackSource(
            file: FixtureLocator.audio("two-speakers-alternating.wav"),
            realtime: false)
        let output = try await pipeline.run(
            configuration: .init(
                recordingFolder: folder,
                recordingStart: fixedStart,
                recordingId: "rec_two-speakers-alternating",
                liveDiarizerConfig: nil),
            systemTranscriber: transcriber,
            systemSource: source,
            library: nil)

        let text = try String(contentsOf: output.liveURL, encoding: .utf8)
        let lower = text.lowercased()
        // Distinctive fixture words, extracted from the retired whisper
        // snapshot (git history: __Snapshots__/StreamingPipelineTests/
        // liveMDSnapshot.1.txt). Case-insensitive `contains`: robust to
        // small wording drift between decoders, loud on a real break.
        for keyword in ["coffee", "barista", "bookstore", "ingestion", "transformation"] {
            #expect(lower.contains(keyword), "live.md should mention '\(keyword)'")
        }

        // Structure: marker first, header second, several non-empty
        // utterance lines whose timestamps never go backwards.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(lines[0] == "<!-- pulsartrace:live -->")
        #expect(lines[1].hasPrefix("## Transcript — "))
        let utterances = lines.filter { $0.hasPrefix("**[") }
        #expect(utterances.count >= 3)
        for line in utterances {
            // "**[HH:MM:SS] label:** text" — text part must be non-empty.
            if let textStart = line.range(of: ":** ") {
                #expect(!line[textStart.upperBound...]
                    .trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        let stamps = utterances.compactMap { line -> String? in
            guard let close = line.firstIndex(of: "]") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 3)..<close])
        }
        #expect(stamps == stamps.sorted(), "utterance timestamps must be monotonic")
    }
```

(`"HH:MM:SS"` strings sort lexicographically in time order — that is what the snapshot's `[00:00:00] … [00:00:20]` prefixes look like.)

6. In `realtimePacedRunBoundedLag`, replace the transcriber construction the same way (drop `WhisperTestGate.run` + `WhisperTestTranscriber.make`, use `ParakeetTestEngine.shared()` + `ParakeetWindowTranscriber`), keep every assertion, and update the test's R10 doc comment: the old text explains CPU-whisper lag; replace that paragraph with:

```swift
    /// Note on R10: Parakeet on the ANE decodes far faster than real time,
    /// so lag should stay small here; the assertion below is deliberately
    /// the same *bounded*-lag invariant as before (not a tight latency
    /// target — that's the manual smoke test's job), so a slow first-run
    /// model load cannot flake this test.
```

- [ ] **Step 9: Retire the live.md snapshot file**

```bash
git rm Tests/PipelineTests/__Snapshots__/StreamingPipelineTests/liveMDSnapshot.1.txt
```

- [ ] **Step 10: Build and run the affected filters**

Run: `swift build`
Expected: compiles.
Run: `swift test --filter Streaming`
Expected: PASS (first run may download the Parakeet model).
Run: `swift test --filter LiveRunner`
Expected: PASS — LiveRunner's suites still use whisper test transcribers, untouched until task 16.
Run: `swift test --filter RecordOrchestrator`
Expected: PASS.
Run: `swift test --filter UnitTests`
Expected: PASS.

- [ ] **Step 11: Prove the live path end-to-end on a fixture (manual, fast)**

Run: `.build/debug/pulsartrace-engine --live --source fixture Tests/Fixtures/audio/single-speaker-30s.wav --out /tmp/parakeet-live-smoke --no-live-diarization` (bare; `dangerouslyDisableSandbox: true`)
Expected: exits 0, prints `live.md=… lines=N` with N ≥ 1. Then read `/tmp/parakeet-live-smoke/live.md` — it must carry the `<!-- pulsartrace:live -->` marker and dated utterance lines whose text matches the fixture's speech. This is the LocalAgreement-2 compatibility proof: per-word segments + deterministic TDT decode → words commit.

- [ ] **Step 12: Commit**

```bash
git add Sources/pulsartrace-engine/main.swift Sources/PulsarTraceEngine/Refinement/RecordPlan.swift Sources/pulsartrace/RecordCommand.swift Sources/PulsarTraceMenuBar/RecordingViewModel.swift Tests/UnitTests/RecordPlanTests.swift Tests/PipelineTests/ParakeetTestEngine.swift Tests/PipelineTests/ParakeetTranscriberTests.swift Tests/PipelineTests/StreamingPipelineTests.swift
git commit -m "feat(live): cut the live pass over to Parakeet v3 — no live model knob anywhere"
```
