# Live Diarizer Over-Split Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the live diarizer from over-splitting a single speaker into multiple provisional keys (which the R18 library lookup then confidently mis-names) by giving the live windowed pass its own FluidAudio clustering tuning, without touching the refine pass.

**Architecture:** `DiarizerEngine` currently owns one `OfflineDiarizerManager` shared by both the refine pass (`diarize(wavPath:)`) and the live windowed pass (`diarize(samples:)`). We split it into two managers — `refineManager` (FluidAudio's default AHC clustering threshold, 0.6) and `liveManager` (a higher threshold, 1.05) — that load the diarizer models independently. The live path routes to `liveManager`; the refine path keeps `refineManager` byte-for-byte. The embedding model is identical in both, so the WeSpeaker vector space (R29) is unchanged; only the agglomerative-clustering distance threshold differs.

**Tech Stack:** Swift 6 (actors, Swift Concurrency), Swift Testing, FluidAudio 0.15.2 (`OfflineDiarizerManager` CoreML/ANE — segmentation + WeSpeaker embeddings + AHC + VBx clustering).

---

## Background (why this change)

- **Symptom:** in the live pass, two known system-stream speakers (Mateusz + Stanisław) were both labelled `Mateusz (Revoize)?`, while the refine pass separated them correctly. An earlier "per-segment embeddings" attempt (abandoned, never merged) made it worse.
- **Root cause:** the live pass runs FluidAudio's full offline pipeline on each ~10 s window (`engine.diarize(samples:)`), then stitches per-window cluster embeddings into a running bank. FluidAudio's per-window clustering is noisier than the retired pyannote pipeline's on short windows — it **over-splits a single speaker** into 2–3 clusters. Each spurious fragment becomes its own provisional key, and the R18 library lookup resolves it to whatever speaker its (noisy) centroid is nearest — including an unrelated third person.
- **The lever:** FluidAudio's AHC step uses `clustering.threshold` (a Euclidean distance on unit-normalized embeddings; default `0.6`). Raising it merges within-speaker fragments back together. Real distinct speakers sit far enough apart that they stay split.
- **Calibration (measured 2026-06-15, live windowed path = `engine.diarize(samples:)` per 10 s window / 5 s step + the 0.45 cosine stitch):**

  | clip | thr=0.60 | 0.75 | 0.90 | **1.05** | 1.20 |
  |---|---|---|---|---|---|
  | `single-speaker-30s` (committed) | 1 | 1 | 1 | **1** | 1 |
  | `two-speakers-alternating` (committed) | 2 | 2 | 2 | **2** | 2 |
  | real 2-speaker recording | 3 | 3 | 3 | **2** | 2 |

  At the default `0.60` the real recording forms **3** keys; the spurious one resolved (R18) to a *third* library speaker at cosine 0.91. At **1.05** it forms exactly **2**, resolving to `Mateusz (Revoize)` (0.95) and `Stanisław (Revoize)` (0.92), and the committed fixtures are unchanged. `1.05` is the lowest value that fixes the over-split; the validated-safe band is 1.05–1.20 (max allowed is √2 ≈ 1.414, enforced by FluidAudio's `config.validate()`).

## Preconditions (verify, do not redo)

- On branch `feat/ane-transcription-pipeline`. `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift` is at its base state: a single `manager` property, `diarize(samples:)` and `diarize(wavPath:)` both calling `manager.process(...)`. (If `diarizeWindowSegments` / `exposeChunkEmbeddings` exist, you are on the wrong branch — that was the abandoned approach.)
- `swift build` (bare, `dangerouslyDisableSandbox: true`) → `Build complete!`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift` | Resident FluidAudio diarization stack | **Modify** — two managers (refine + live), live-only AHC threshold; route each `diarize` overload to its manager |
| `Tests/PipelineTests/DiarizationE2ETests.swift` | E2E against real CoreML models | **Modify** — add two live-path key-count regression tests |

No new files, no new types. One new constant on `DiarizerEngine`.

## A note on test coverage (read before Task 2)

The over-split reproduces only on real conversational audio — **not** on the committed fixtures (the table above: `single-speaker-30s` is 1 key and `two-speakers-alternating` is 2 keys at *every* threshold, including the buggy 0.6). So there is **no committed test that goes red at 0.6 and green at 1.05** — this is a calibration change, like the existing `warmStartFa = 0.2`. Task 2's tests are therefore **invariant guards** (they pass before and after; they lock the live path's key counts so a future regression — e.g. someone unifying the thresholds, or the per-segment idea returning — is caught). The fix's real-world efficacy is evidenced by the calibration table (recorded in the threshold's doc comment) and confirmed by the Manual Validation section. This is intentional and honest; do not fabricate a red-green cycle the fixtures cannot support.

---

## Task 1: Give the live path its own clustering threshold

Split `DiarizerEngine`'s single manager into `refineManager` (unchanged) + `liveManager` (raised AHC threshold), and route each `diarize` overload accordingly.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`

- [ ] **Step 1: Update the class doc comment**

Replace the class doc comment (the `///` block immediately above `public actor DiarizerEngine {`, currently lines ~5–15) with:

```swift
/// The resident FluidAudio offline-diarization stack (D40/D41) — pyannote
/// community-1 ported to CoreML, segmentation + WeSpeaker embeddings + AHC/VBx
/// clustering on the ANE. Owns two `OfflineDiarizerManager`s: one for the
/// offline refine pass (`Diarizer`) and one for the live windowed pass
/// (`LiveDiarizer`). Both use the same embedding model, so their embeddings
/// share one vector space (R29) and the speaker library compares across them;
/// they differ only in the AHC clustering threshold (D41 — see
/// `liveClusteringThreshold`). Each loads the (small) diarizer models
/// independently; the duplication is negligible next to the Parakeet/WhisperKit
/// residency and buys each manager FluidAudio's own prewarm + corrupt-cache
/// recovery. Models live at `<cacheRoot>/speaker-diarization/` (FluidAudio's
/// `DownloadUtils` appends `Repo.diarizer.folderName`, which strips the
/// `-coreml` suffix, to the directory it is handed) — the same D10 cache root
/// Parakeet and FluidVAD use.
```

- [ ] **Step 2: Add the `liveClusteringThreshold` constant**

In `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`, immediately after the `requiredBundles` declaration (currently ends ~line 30, before the `manager` property), add:

```swift
    /// AHC agglomerative-clustering distance threshold for the LIVE windowed
    /// path (D41). FluidAudio's default (0.6) over-splits a single speaker on
    /// the short (~10 s) windows the live pass feeds it: on a real 2-speaker
    /// recording the live bank formed 3 provisional keys — one a spurious
    /// within-speaker fragment that the R18 lookup confidently mis-named to a
    /// third library speaker (cosine 0.91). Raising the threshold merges those
    /// fragments while genuinely distinct speakers stay split. Calibrated
    /// 2026-06-15 (live path, 10 s window / 5 s step + the 0.45 cosine stitch):
    /// at 1.05 the same recording yields exactly 2 keys → Mateusz + Stanisław
    /// (0.95 / 0.92); the committed `single-speaker-30s` fixture stays 1 and
    /// `two-speakers-alternating` stays 2; the validated-safe band is 1.05–1.20
    /// (max is √2, enforced by `OfflineDiarizerConfig.validate()`). The refine
    /// pass keeps FluidAudio's 0.6 default — whole-file evidence clusters
    /// correctly and is the source of truth (R16).
    static let liveClusteringThreshold = 1.05
```

- [ ] **Step 3: Replace the single `manager` property with two managers**

Replace the `manager` property and its doc comment (currently lines ~32–40, the `/// OfflineDiarizerManager is a non-Sendable final class…` block plus `private nonisolated(unsafe) let manager: OfflineDiarizerManager`) with:

```swift
    /// `OfflineDiarizerManager` is a non-Sendable `final class`. This actor is
    /// the sole owner of both managers and every `process` call goes through an
    /// actor-isolated `diarize` method. Actors are reentrant across `await`, so
    /// two `process` calls on one manager CAN overlap — but only when a caller
    /// abandons a cancelled call still winding down (the live window-timeout
    /// path), and CoreML `MLModel.prediction` is documented thread-safe.
    /// `nonisolated(unsafe)` accepts that bounded overlap; do not add callers
    /// that run uncancelled `diarize` calls concurrently on the same manager.
    /// The refine and live managers are separate instances with separate model
    /// objects, so the refine pass and a live window never contend.
    private nonisolated(unsafe) let refineManager: OfflineDiarizerManager
    private nonisolated(unsafe) let liveManager: OfflineDiarizerManager
```

- [ ] **Step 4: Update the private initializer**

Replace the initializer (currently lines ~47–50):

```swift
    private init(manager: OfflineDiarizerManager, modelRevision: String) {
        self.manager = manager
        self.modelRevision = modelRevision
    }
```

with:

```swift
    private init(
        refineManager: OfflineDiarizerManager,
        liveManager: OfflineDiarizerManager,
        modelRevision: String
    ) {
        self.refineManager = refineManager
        self.liveManager = liveManager
        self.modelRevision = modelRevision
    }
```

- [ ] **Step 5: Build both managers in `load(...)`**

In `load(...)`, replace the block that builds the single manager (currently from `var config = OfflineDiarizerConfig.default` through `try await manager.prepareModels(directory: cacheRoot)`, lines ~72–88) with:

```swift
        var config = OfflineDiarizerConfig.default
        // Keep overlap-preserving spans: the transcript merge's 30 %
        // co-attribution rule (D11) needs overlapping speaker spans.
        config.postProcessing.exclusiveSegments = false
        // VBx evidence weight, raised from FluidAudio's 0.07 default (D40).
        // At 0.07 the clusterer collapses two clearly-distinct voices
        // (cross-speaker cosine 0.38, same-speaker 0.93) into one cluster on
        // recordings shorter than ~1 minute — VBx's prior dominates until
        // enough audio accumulates (the same 24 s clip separates at 72 s).
        // Measured on the committed fixtures: every Fa in 0.08…0.3 separates
        // the two-speaker clip and none splits a 2-minute single-speaker
        // clip; 0.2 sits well clear of the 0.07/0.08 boundary. Under-
        // separation is the worse failure (two people fused under one label,
        // unfixable post-hoc); over-split has a user remedy (speaker merge).
        config.clustering.warmStartFa = 0.2

        // Refine pass: FluidAudio's default AHC threshold (0.6) — whole-file
        // evidence clusters correctly; this pass is the source of truth.
        let refineManager = OfflineDiarizerManager(config: config)
        try await refineManager.prepareModels(directory: cacheRoot)

        // Live pass: identical config but a higher AHC threshold so a single
        // speaker does not over-split on the short windows it processes (D41).
        var liveConfig = config
        liveConfig.clustering.threshold = liveClusteringThreshold
        let liveManager = OfflineDiarizerManager(config: liveConfig)
        try await liveManager.prepareModels(directory: cacheRoot)
```

- [ ] **Step 6: Return both managers from `load(...)`**

Replace the final `return` of `load(...)` (currently line ~101):

```swift
        return DiarizerEngine(manager: manager, modelRevision: digest.sha256)
```

with:

```swift
        return DiarizerEngine(
            refineManager: refineManager,
            liveManager: liveManager,
            modelRevision: digest.sha256)
```

- [ ] **Step 7: Route `diarize(samples:)` to the live manager**

In `diarize(samples:)`, change the one process call (currently line ~116):

```swift
            let raw = try await manager.process(audio: samples)
```

to:

```swift
            let raw = try await liveManager.process(audio: samples)
```

- [ ] **Step 8: Route `diarize(wavPath:)` to the refine manager**

In `diarize(wavPath:)`, change the one process call (currently line ~141):

```swift
            let raw = try await manager.process(wavPath)
```

to:

```swift
            let raw = try await refineManager.process(wavPath)
```

- [ ] **Step 9: Build**

Run (bare, `dangerouslyDisableSandbox: true`): `swift build`
Expected: `Build complete!` (no reference to the removed `manager` property remains — Steps 7 and 8 are the only two `process` call sites).

- [ ] **Step 10: Run the diarization E2E suite to confirm no regression**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter DiarizationE2E`
Expected: all pass. The refine-path tests (`twoSpeakersSeparate`, `singleSpeaker`, `twoSpeakersAlternatingShape`, `diarizerActorEndToEnd`) are unaffected (refine manager unchanged). The live-path tests (`windowedPassYieldsStableProvisionalKeys`, `thresholdsSeparateSameFromCross`, `silenceYieldsEmptyResultNotError`) still pass — at 1.05 the committed fixtures yield the same speaker counts (1 and 2) and the same/cross cosine thresholds are embedding-space properties unchanged by clustering.

- [ ] **Step 11: Commit**

```bash
git add Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift
git commit -m "fix(live): live-only AHC threshold to stop per-window over-split (D41)"
```

---

## Task 2: Live-path key-count regression guards

Lock the live windowed pass's key counts on the committed fixtures so a future regression (over-split returning, or the thresholds being unified) is caught. See "A note on test coverage" above — these are invariant guards, green before and after; they are not a red-green cycle.

**Files:**
- Modify: `Tests/PipelineTests/DiarizationE2ETests.swift`

- [ ] **Step 1: Add the two tests**

Inside the `DiarizationE2ELiveTests` struct (the `@Suite("DiarizationE2E live windowed", .serialized)` one — it already has the `fixtureSamples(_:)` helper), add:

```swift
    /// D41 over-split guard: the live windowed pass over the single-speaker
    /// clip must form exactly ONE provisional key. FluidAudio's default AHC
    /// threshold can split one speaker into several on the short windows the
    /// live pass uses; `DiarizerEngine.liveClusteringThreshold` counters that.
    @Test func liveWindowedPassKeepsSingleSpeakerAsOneKey() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let live = LiveDiarizer(engine: engine)
        let samples = try await fixtureSamples("single-speaker-30s.wav")

        let window = AudioFormat.sampleRate * 10
        let step = AudioFormat.sampleRate * 5
        var keys = Set<String>()
        var start = 0
        while start + window <= samples.count {
            let spans = await live.diarizeWindow(
                samples: Array(samples[start..<(start + window)]),
                windowStart: .milliseconds(start * 1000 / AudioFormat.sampleRate))
            for s in spans { keys.insert(s.provisionalKey) }
            start += step
        }
        #expect(keys == ["Them"], "single speaker over-split into \(keys)")
    }

    /// D41: separation is preserved at the higher live threshold — the live
    /// windowed pass over the two-speaker clip forms exactly TWO keys.
    @Test func liveWindowedPassFormsTwoKeysForTwoSpeakers() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let live = LiveDiarizer(engine: engine)
        let samples = try await fixtureSamples("two-speakers-alternating.wav")

        let window = AudioFormat.sampleRate * 10
        let step = AudioFormat.sampleRate * 5
        var keys = Set<String>()
        var start = 0
        while start + window <= samples.count {
            let spans = await live.diarizeWindow(
                samples: Array(samples[start..<(start + window)]),
                windowStart: .milliseconds(start * 1000 / AudioFormat.sampleRate))
            for s in spans { keys.insert(s.provisionalKey) }
            start += step
        }
        #expect(keys.count == 2, "expected 2 live speakers, got \(keys)")
    }
```

- [ ] **Step 2: Run them**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter DiarizationE2E`
Expected: all pass, including the two new tests (`keys == ["Them"]` for the single-speaker clip; `keys.count == 2` for the two-speaker clip).

- [ ] **Step 3: Commit**

```bash
git add Tests/PipelineTests/DiarizationE2ETests.swift
git commit -m "test(live): guard live-path key counts on the committed fixtures (D41)"
```

---

## Verification (run before declaring done)

Per CLAUDE.md, verify with the narrow filters (bare commands, `dangerouslyDisableSandbox: true`) — never `--filter PipelineTests` broadly:

- [ ] `swift build` → `Build complete!`
- [ ] `swift test --filter DiarizationE2E` → all pass (incl. the two new live-path tests)
- [ ] `swift test --filter Streaming` → all pass (LiveDiarizer is untouched; this confirms the engine-routing change didn't disturb the live pipeline)
- [ ] `swift test --filter UnitTests` → all pass

If any test fails — even one you think is unrelated — it is yours per the project's no-failing-tests rule: fix the cause, gate it explicitly, or escalate.

## Manual validation (the real-world check the fixtures can't give)

The committed fixtures do not reproduce the over-split, so confirm the fix on real audio:

- [ ] Rebuild the app (`pulsartrace-mac`) and run a real multi-speaker call (or replay one), and confirm the live transcript shows distinct speakers without a spurious third name.
- Optional reproducible check on a known recording: run the live windowed pass (`engine.diarize(samples:)` per 10 s window / 5 s step) over a real 2-speaker WAV, stitch with the 0.45 cosine bank, and confirm exactly 2 keys that resolve via `SpeakerLibrary.bestMatch` to the two expected names. (This is how `1.05` was calibrated; the harness is throwaway and references a local recording path, so it is not committed.)

## Out of scope (do not touch)

- The offline refine pass (`Diarizer`, `engine.diarize(wavPath:)`, `refineManager`) — unchanged; it stays the source of truth.
- `LiveDiarizer` and its 0.45 cosine stitch — unchanged; the fix is entirely in the per-window clustering the engine hands it.
- The WeSpeaker embedding model / model revision (R29) and the speaker library — unchanged (same embedding model in both managers).
- Window geometry (`diarizationWindow = 10 s`, `diarizationStep = 5 s`).

## Risks / known limitations

- **Over- vs under-split tension:** raising the live threshold cures over-splitting (the spurious extra speaker) but cannot cure *under*-splitting (two speakers merged into one on a window) — that needs the opposite move. Validated cases (`two-speakers-alternating`, the real recording) do **not** merge at 1.05, but a meeting with two very similar voices could. If under-split resurfaces on real calls, that is a separate problem (it is partly why a longer/whole-file refine pass exists); do not chase it by lowering this threshold, which would reintroduce the over-split.
- **No committed reproduction:** see "A note on test coverage". The guards in Task 2 protect the invariants; real-world efficacy rests on the calibration data and the manual check.
