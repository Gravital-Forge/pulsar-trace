> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 13: Refine queue cutover — WhisperKit/FluidVAD only

`RefinementJobQueue.makeStandard` becomes WhisperKit-only (no backend branch, no `whisperBinaryURL:` parameter), `ResumableRefiner.DetectRegions` becomes async (FluidVAD is an actor), and the `pulsartrace-whisper` binary threading (`PULSARTRACE_WHISPER_BINARY`) is removed wholesale — after task 12 the live path no longer reads it either. Enqueue resolution moves to `WhisperKitModelCatalog`.

Types from earlier tasks used here: `WhisperKitModelCatalog.model(named:)`/`defaultModel` (task 03), `WhisperKitRegionTranscriber(configuration: .init(model:downloadBase:), events:)` with `transcribeRegion(_:region:options:)` (task 11), `FluidVADRegionDetector().detectRegions(_:)` (task 09).

**Files:**
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift:18-19` (`DetectRegions` → async) and `:180,:199` (`try` → `try await`)
- Modify: `Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift:398-515` (`makeStandard`) and the stale subprocess comments at `:203-221` and `:235-240`
- Modify: `Sources/PulsarTraceMenuBar/AppEnvironment.swift:158-178`
- Modify: `Sources/PulsarTraceMenuBar/RecordingViewModel.swift` (`defaultOrchestratorFactory`, ~line 423)
- Modify: `Sources/pulsartrace/RecordCommand.swift` (orchestrator env, ~lines 103–116)
- Modify: `Sources/PulsarTraceEngine/Engine/RecordOrchestrator.swift:28-35` (doc comment only)
- Modify: `Sources/PulsarTraceMenuBar/RefinementQueueHandle.swift:61-66`, `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift:128-134`
- Test: `Tests/MenuBarTests/RefinementQueueHandleTests.swift:129-154`, plus compile-fix fallout in `Tests/UnitTests/ResumableRefinerTests.swift` / `Tests/PipelineTests/RefinementJobQueueTests.swift`

- [ ] **Step 1: Make `DetectRegions` async**

In `ResumableRefiner.swift` (line 18):

```swift
    public typealias DetectRegions =
        @Sendable ([Float]) async throws -> [SpeechRegion]
```

and in `transcribeSystemStream` / `transcribeMicStream` (lines ~180 and ~199), change `let regions = try detectRegions(samples)` to:

```swift
            let regions = try await detectRegions(samples)
```

(`TranscribeRegion` is already `async throws` — verified line 15 — no change.)

- [ ] **Step 2: Build; fix the compile fallout mechanically**

Run: `swift build` (bare; `dangerouslyDisableSandbox: true` per CLAUDE.md — same below)
Expected: errors only at closure-literal call sites (`makeStandard` — rewritten next step anyway — and tests). A synchronous closure satisfies an async typealias automatically in most positions; where the compiler objects in `Tests/UnitTests/ResumableRefinerTests.swift` or `Tests/PipelineTests/RefinementJobQueueTests.swift`, no body change is needed beyond accepting the async type. Fix and rebuild until green.

- [ ] **Step 3: Rewrite `makeStandard` — WhisperKit only, no binary URL**

In `RefinementJobQueue.swift`, change the signature (delete the `whisperBinaryURL:` parameter and the entire doc paragraph about it at lines ~398–406 — there is no binary to resolve any more):

```swift
    public static func makeStandard(
        events: EventWriter,
        paths: AppPaths = .standard,
        whisperOptions: WhisperOptions = .init()
    ) async -> RefinementJobQueue {
```

and replace the `runJob` closure body (from `let modelStore = ModelStore(events: events)` through `try await refiner.run(job: job)`) with:

```swift
        let runJob: RunJob = { [weak queue] job in
            guard let queue else { return }
            // ANE refine (D39): in-process WhisperKit + FluidAudio VAD. The
            // job's model name resolves against the WhisperKit catalog; an
            // unknown name (e.g. a job enqueued by an older build) falls
            // back to the default rather than failing the job.
            let model = WhisperKitModelCatalog.model(named: job.modelName)
                ?? WhisperKitModelCatalog.defaultModel

            let diarizer = try OfflineRefiner.makeDiarizer()

            // Register the diarizer so pauseForRecording() can cancel it
            // mid-run (D-Q7). Clearing the slot is the queue's
            // responsibility (done synchronously in runNext() after _runJob
            // returns).
            await queue.setInflightCancellable(diarizer)

            // One transcriber per *job*, not per region — the model loads
            // once on the first region decode and stays resident across the
            // job. The release hook lets pauseForRecording() drop the box's
            // actor: ARC frees the CoreML models — the in-process analogue
            // of SIGTERMing the old `pulsartrace-whisper` subprocess before
            // a recording starts.
            let box = SharedTranscriberBox<WhisperKitRegionTranscriber> {
                WhisperKitRegionTranscriber(
                    configuration: .init(
                        model: model,
                        downloadBase: ModelStore.defaultCacheDirectory()
                            .appendingPathComponent("whisperkit", isDirectory: true)),
                    events: events)
            }
            let vad = FluidVADRegionDetector()
            await queue.setInflightTranscriberRelease { [box] in
                box.release()
            }

            let refiner = ResumableRefiner(
                transcribe: { samples, region, options in
                    let t = try box.get()
                    return try await t.transcribeRegion(
                        samples, region: region, options: options)
                },
                detectRegions: { samples in
                    do {
                        return try await vad.detectRegions(samples)
                    } catch {
                        // VAD failure must not lose a refine: one region
                        // spanning the whole stream — WhisperKit's internal
                        // seek loop handles the length. (The old path's
                        // equivalent fallback was the whole-buffer decode.)
                        return [SpeechRegion(
                            start: .zero,
                            end: .milliseconds(
                                samples.count * 1000 / AudioFormat.sampleRate))]
                    }
                },
                diarize: { wav in
                    try await diarizer.diarizeSystemStream(wavPath: wav)
                },
                pauseGate: gate,
                events: events,
                library: library,
                whisperOptions: whisperOptions,
                onStageUpdate: { [weak queue] state in
                    guard let queue else { return }
                    await queue.reportStage(state)
                })
            try await refiner.run(job: job)
        }
```

Keep the two-step-init and library-setup comments above the closure; they still apply.

- [ ] **Step 4: Refresh the stale subprocess comments in the same file**

1. In the `pauseForRecording()` doc comment (lines ~200–221), replace the "**Phase 6 behaviour change.**" paragraph and its numbered list with:

```swift
    /// **Why this does more than close the gate.** "Complete the current
    /// region" can be many seconds, during which the resident WhisperKit
    /// models hold ANE/memory the live pass is about to want. So this
    /// method also:
    ///
    /// 1. Fires the in-flight transcriber-release hook (if registered),
    ///    which drops the `SharedTranscriberBox`'s cached
    ///    `WhisperKitRegionTranscriber` — ARC frees the CoreML models.
    /// 2. Awaits the worker task's exit (the in-flight `transcribeRegion`
    ///    throws once the actor is gone; `ResumableRefiner.run` propagates
    ///    the throw; the worker exits). A 5-second timeout caps the wait.
```

   Keep the surrounding sentences ("The killed region is *not* lost…" still applies verbatim).
2. In the body comment at lines ~235–240 ("Phase 6: fire the transcriber-release hook so the refinement `pulsartrace-whisper` subprocess terminates promptly…"), replace the first sentence block with:

```swift
        // Fire the transcriber-release hook so the resident WhisperKit
        // models are freed promptly (ARC on the dropped actor) before the
        // live pass loads its own model.
```

   Keep the "Only if a release hook was registered…" explanation that follows — its logic is unchanged.

- [ ] **Step 5: Drop the whisper-binary threading from the menubar + CLI**

1. `Sources/PulsarTraceMenuBar/AppEnvironment.swift` (~lines 158–178): delete the `whisperBinaryURL` resolution and its long comment, and the `whisperBinaryURL:` argument:

```swift
        // Mirror the live path's language allow-list into refinement
        // (R-streaming-lang). Without this, refinement decoded each region
        // with unrestricted auto-detect, so a quiet/ambiguous stretch in a
        // Polish meeting could drift to Spanish or Russian even when the
        // user had restricted the language set in Settings.
        let refineWhisperOptions = WhisperOptions(
            allowedLanguages: settings.allowedLanguages)
        let q = await RefinementJobQueue.makeStandard(
            events: events,
            paths: paths,
            whisperOptions: refineWhisperOptions)
```

   (Do NOT add a language parameter — `allowedLanguages` + the task 10/11 policy already cover refinement language selection.)
2. `Sources/PulsarTraceMenuBar/RecordingViewModel.swift`, `defaultOrchestratorFactory` (~line 423): delete the `engineEnvironment:` dictionary (and the factory's doc-comment paragraph about `PULSARTRACE_WHISPER_BINARY`):

```swift
    /// Production orchestrator factory — a real `RecordOrchestrator`.
    nonisolated static let defaultOrchestratorFactory:
        @Sendable (RecordPlan, @escaping @Sendable (String) -> URL) -> RecordingOrchestrating
    = { plan, resolve in
        RecordOrchestrator(configuration: .init(
            captureBinary: resolve("pulsartrace-capture"),
            captureArguments: plan.captureArguments,
            engineBinary: resolve("pulsartrace-engine"),
            engineArguments: plan.engineArguments))
    }
```

   Also trim `defaultBinaryURLResolver`'s doc comment (~line 410): delete the sentence about reusing it "to locate `pulsartrace-whisper`" — it still resolves `pulsartrace-capture`/`pulsartrace-engine`.
3. `Sources/pulsartrace/RecordCommand.swift` (~lines 103–116): delete the `engineEnvironment:` dictionary and the comment above it:

```swift
        let orchestrator = RecordOrchestrator(configuration: .init(
            captureBinary: binDir.appendingPathComponent("pulsartrace-capture"),
            captureArguments: plan.captureArguments,
            engineBinary: binDir.appendingPathComponent("pulsartrace-engine"),
            engineArguments: plan.engineArguments))
```

4. `Sources/PulsarTraceEngine/Engine/RecordOrchestrator.swift` (~lines 28–35): the `engineEnvironment` **mechanism stays** (generic subprocess-env merge, covered by `RecordOrchestratorTests`' env-merge tests; production now passes `nil`). Replace the "Used in production to set `PULSARTRACE_WHISPER_BINARY`…" doc paragraph with:

```swift
        /// No production caller sets this today (the engine subprocess
        /// resolves everything it needs itself); kept as the generic
        /// subprocess-environment seam, exercised by RecordOrchestratorTests.
```

5. Verify nothing else threads the variable:

Run: `grep -rn "PULSARTRACE_WHISPER_BINARY" Sources/ Tests/`
Expected: hits only inside `Sources/PulsarTraceEngine/WhisperIPC/WhisperBinaryResolver.swift` (the env-var *reader*, deleted in task 16) and a stale comment in `Tests/PipelineTests/RecordOrchestratorTests.swift:92` (updated in task 16). No production *writer* remains.

(`RecordingViewModel.waitForWhisperLockFree` + `WhisperLockProbe` are deliberately untouched here — they guard the binary-level `whisper.lock`, which is dead only once WhisperIPC is deleted; task 16 removes them with it.)

- [ ] **Step 6: Move enqueue resolution to the WhisperKit catalog**

1. `Sources/PulsarTraceMenuBar/RefinementQueueHandle.swift` (~line 61), replace the `ModelCatalog` lookup:

```swift
        let model = WhisperKitModelCatalog.model(named: settings.refineModelName)
            ?? WhisperKitModelCatalog.defaultModel
        do {
            try await queue.enqueueAutoRefine(
                folderURL: folderURL, recordingId: recordingId,
                modelName: model.name,
                modelSHA256: "")   // SDK-managed CoreML bundle (D39)
```

2. `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift` (~line 128), same substitution in `enqueueManual(folderURL:recordingId:refineModelName:)`:

```swift
        let model = WhisperKitModelCatalog.model(named: refineModelName)
            ?? WhisperKitModelCatalog.defaultModel
        await enqueueManual(
            folderURL: folderURL, recordingId: recordingId,
            modelName: model.name, modelSHA256: "")
```

3. Both files may need `import PulsarTraceEngine` — check the top of each (they already use engine types, so the import is almost certainly present; the compiler will say).

- [ ] **Step 7: Update the enqueue-resolution tests**

In `Tests/MenuBarTests/RefinementQueueHandleTests.swift`, test `enqueueResolvesModelFromLiveSettings` (~lines 129–154): replace the `ModelCatalog` expectations:

```swift
        // Changed AFTER the handle was created — the handle must read the
        // value at enqueue time, exactly like the old EnqueueBox impl.
        settings.refineModelName = WhisperKitModelCatalog.largeV3.name
        await handle.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/live-settings"),
            recordingId: "rec_live")
        let live = try await waitForRecent(queue, recordingId: "rec_live")
        #expect(live?.modelName == "large-v3-whisperkit")
        #expect(live?.modelSHA256 == "")   // CoreML bundles carry no pin (D39)

        // An unknown model name falls back to the catalog default.
        settings.refineModelName = "no-such-model"
        await handle.enqueueAutoRefine(
            folderURL: URL(fileURLWithPath: "/tmp/fallback"),
            recordingId: "rec_fallback")
        let fallback = try await waitForRecent(queue, recordingId: "rec_fallback")
        #expect(fallback?.modelName == "large-v3-turbo")
        #expect(fallback?.modelSHA256 == "")
```

(Add `import PulsarTraceEngine` to the test file if `WhisperKitModelCatalog` doesn't resolve.) Then grep for any other `ModelCatalog` use in MenuBar tests and fix the same way: `grep -rn "ModelCatalog" Tests/MenuBarTests/` — expected: none left except via this file.

- [ ] **Step 8: Run the refinement + menubar suites**

Run: `swift build`
Expected: compiles.
Run: `swift test --filter Refinement`
Expected: PASS. The queue unit/pipeline tests inject their own `runJob` closures and never exercise `makeStandard`'s production wiring, so they pass without a model download. (Any test that does hit the real WhisperKit path pays the one-time download from task 11's run.)
Run: `swift test --filter MenuBar`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/PulsarTraceEngine/Refinement/Jobs/ResumableRefiner.swift Sources/PulsarTraceEngine/Refinement/Jobs/RefinementJobQueue.swift Sources/PulsarTraceMenuBar/AppEnvironment.swift Sources/PulsarTraceMenuBar/RecordingViewModel.swift Sources/PulsarTraceMenuBar/RefinementQueueHandle.swift Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift Sources/pulsartrace/RecordCommand.swift Sources/PulsarTraceEngine/Engine/RecordOrchestrator.swift Tests
git commit -m "feat(refine): queue runs WhisperKit + FluidVAD on the ANE — whisper binary threading removed"
```
