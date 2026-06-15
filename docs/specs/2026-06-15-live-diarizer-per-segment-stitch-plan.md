# Live Diarizer Per-Segment Stitch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use pulsartrace-subagent-driven-development (recommended) or pulsartrace-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the live pass collapsing multiple system-stream speakers into one provisional key by stitching FluidAudio's per-segment embeddings (segmentation stage) into the running speaker bank, bypassing the per-window VBx clustering that under-separates on short windows.

**Architecture:** The live `LiveDiarizer` already keeps an online speaker bank (`liveSpeakers` + `stitchKey`). Today it feeds that bank the *post-VBx* one-cluster-per-window result, and VBx collapses two voices into one on the ~10 s windows the live pass uses. We switch the input to the *pre-clustering* per-segment embeddings (`DiarizerEngine.diarizeWindowSegments`, already landed) and assign each segment to the bank ourselves. The offline refine pass is unchanged — VBx stays correct there with whole-file evidence.

**Tech Stack:** Swift 6 (actors, Swift Concurrency), Swift Testing, FluidAudio 0.15.2 (`OfflineDiarizerManager` CoreML/ANE — WeSpeaker embeddings + VBx).

---

## Background (why this change)

- **Symptom (2026-06-15 call):** every system-stream line in `live.md` was labelled `Mateusz (Revoize)?`; the refine pass correctly split Mateusz and Stanisław. The live pass emitted effectively one provisional key for two voices.
- **Root cause:** `LiveDiarizer.diarizeWindow` calls `engine.diarize(samples:)`, which runs FluidAudio's full offline pipeline (segmentation → embeddings → **VBx clustering**) on each 10 s window and returns one centroid *per VBx cluster*. VBx's prior dominates on sub-minute audio and frequently returns a single cluster, so the bank only ever sees one embedding per window and merges everything.
- **Spike result (`Tests/PipelineTests/DiarizationSpikeTests.swift`, run 2026-06-15 on the real recording):**
  - Per-segment WeSpeaker embeddings **separate the two speakers cleanly**: same-speaker cosine ≈ 0.75–0.82, cross-speaker ≈ 0.29–0.35. The existing stitch threshold **0.45** sits in the gap — no recalibration needed.
  - VBx per-window cluster counts were inconsistent (`2,1,1,1,2,2,2` across windows) — it collapsed three of the 10 s windows that demonstrably contained two distinct voices. Confirms the collapse and that it is flaky, not uniform.
  - **New finding:** short segments (≤ ~2 s — the segmentation tail sub-windows) produce noisy embeddings (cosine to the *same* speaker can fall to ~0). The bank must duration-gate them so they cannot spawn ghost speakers or poison centroids.

## Preconditions (already landed during the spike — verify, do not redo)

`Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift` already contains:
- `config.exposeChunkEmbeddings = true` in `load(...)`.
- `public struct WindowSegmentEmbedding { let start: Duration; let end: Duration; let vector: [Float] }`.
- `public func diarizeWindowSegments(samples: [Float]) async throws -> [WindowSegmentEmbedding]` — runs `manager.process(audio:)`, maps `raw.chunkEmbeddings`, drops non-finite vectors, returns `[]` on `noSpeechDetected`.

Verify with: `swift build` (bare, `dangerouslyDisableSandbox: true`). Expected: `Build complete!`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift` | Windowed live diarization + online speaker bank | **Modify** — feed the bank per-segment embeddings; add duration gate + read-only nearest match |
| `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift` | Resident FluidAudio engine | **Done** (preconditions) — no further change |
| `Tests/UnitTests/LiveDiarizerStitchTests.swift` | Unit tests for the per-segment stitch (no models) | **Create** |
| `Tests/PipelineTests/DiarizationE2ETests.swift` | E2E against real CoreML models | **Modify** — add live windowed-pass regression |
| `Tests/PipelineTests/DiarizationSpikeTests.swift` | Throwaway spike on local recording | **Delete** (Task 4) |

No new types beyond `DiarizerEngine.WindowSegmentEmbedding` (already exists) and one constant on `LiveDiarizer`.

---

## Task 1: LiveDiarizer per-segment stitch

Replace the VBx-cluster input with per-segment embeddings and add the duration gate. Test-first: the new test references symbols that don't exist yet, so it won't compile until the implementation lands.

**Files:**
- Create: `Tests/UnitTests/LiveDiarizerStitchTests.swift`
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift`
  - Add constant `minReliableSegment` next to `stitchThreshold` (~line 95)
  - Rewrite `diarizeWindow(samples:windowStart:)` (~lines 126–175)
  - Replace `stitch(result:windowStart:)` with `stitch(segments:windowStart:)` (~lines 177–205)
  - Add `nearestKey(for:)` after `stitchKey(for:)` (~line 235)

- [ ] **Step 1: Write the failing unit tests**

Create `Tests/UnitTests/LiveDiarizerStitchTests.swift`:

```swift
import Foundation
import Testing

@testable import PulsarTraceEngine

/// Unit tests for the live diarizer's per-segment stitching (D40 separation
/// fix). Pure logic — no CoreML models: the diarizer is built with the
/// engine-less test seam and `stitch(segments:windowStart:)` is driven with
/// synthetic embeddings.
@Suite("LiveDiarizerStitch")
struct LiveDiarizerStitchTests {

    /// A 256-d unit basis vector with `1` at `axis` — orthogonal basis vectors
    /// have cosine 0 (distinct speakers); near-duplicates have cosine ~1.
    private func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        v[axis] = 1
        return v
    }

    private func seg(
        _ start: Double, _ end: Double, _ vector: [Float]
    ) -> DiarizerEngine.WindowSegmentEmbedding {
        .init(
            start: .milliseconds(Int(start * 1000)),
            end: .milliseconds(Int(end * 1000)),
            vector: vector)
    }

    @Test func distinctVoicesAcrossWindowsSpawnSecondSpeaker() async {
        let d = LiveDiarizer()   // zero-arg → the engine-less test seam (engine = nil)
        let w0 = await d.stitch(segments: [seg(0, 5, basis(0))], windowStart: .zero)
        let w1 = await d.stitch(segments: [seg(0, 5, basis(1))], windowStart: .seconds(5))
        #expect(w0.map(\.provisionalKey) == ["Them"])
        #expect(w1.map(\.provisionalKey) == ["Them #2"])
        #expect(Set(await d.centroids().keys) == ["Them", "Them #2"])
    }

    @Test func sameVoiceStaysOneSpeaker() async {
        let d = LiveDiarizer()
        _ = await d.stitch(segments: [seg(0, 5, basis(0))], windowStart: .zero)
        var near = basis(0)
        near[1] = 0.1   // cosine to basis(0) ≈ 0.995 → same speaker
        let w1 = await d.stitch(segments: [seg(0, 5, near)], windowStart: .seconds(5))
        #expect(w1.map(\.provisionalKey) == ["Them"])
        #expect(await d.centroids().keys.count == 1)
    }

    @Test func shortSegmentWithEmptyBankIsDropped() async {
        let d = LiveDiarizer()
        let w = await d.stitch(segments: [seg(0, 1, basis(0))], windowStart: .zero)  // 1 s < 2 s
        #expect(w.isEmpty)
        #expect(await d.centroids().isEmpty)
    }

    @Test func shortSegmentLabeledReadOnlyAfterSpeakerExists() async {
        let d = LiveDiarizer()
        _ = await d.stitch(segments: [seg(0, 5, basis(0))], windowStart: .zero)   // Them (reliable)
        let before = await d.centroids()["Them"]

        var near = basis(0)
        near[1] = 0.1
        let w1 = await d.stitch(segments: [seg(0, 1, near)], windowStart: .seconds(5))
        #expect(w1.map(\.provisionalKey) == ["Them"])           // labelled by nearest match
        #expect(await d.centroids().keys.count == 1)
        #expect(await d.centroids()["Them"] == before)          // read-only: centroid unchanged

        let w2 = await d.stitch(segments: [seg(0, 1, basis(1))], windowStart: .seconds(10))
        #expect(w2.isEmpty)                                     // far + short → dropped
        #expect(await d.centroids().keys.count == 1)            // no ghost speaker
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail (do not compile)**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter LiveDiarizerStitch`
Expected: BUILD FAILURE — `value of type 'LiveDiarizer' has no member 'stitch'` (the `stitch(segments:)` overload and `nearestKey` don't exist yet).

- [ ] **Step 3: Add the `minReliableSegment` constant**

In `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift`, immediately after the `stitchThreshold` declaration:

```swift
    /// Segments shorter than this carry unreliable WeSpeaker embeddings — the
    /// segmentation tail sub-windows. Measured in the D40 spike: a ~2 s
    /// segment's cosine to the *same* speaker can fall to ~0. Such segments are
    /// labelled by a read-only nearest match but never create a speaker or
    /// refine a centroid, so they cannot spawn ghosts or poison the bank.
    public static let minReliableSegment: Duration = .seconds(2)
```

- [ ] **Step 4: Rewrite `diarizeWindow` to use per-segment embeddings**

Replace the entire body of `public func diarizeWindow(samples:windowStart:)` with:

```swift
    public func diarizeWindow(
        samples: [Float],
        windowStart: Duration
    ) async -> [LiveSpeakerSpan] {
        guard let engine else { return [] }
        let started = ContinuousClock.now
        windowCounter += 1

        let work = Task { try await engine.diarizeWindowSegments(samples: samples) }
        let segments = await withTaskGroup(
            of: [DiarizerEngine.WindowSegmentEmbedding]?.self
        ) { group -> [DiarizerEngine.WindowSegmentEmbedding]? in
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
        guard let segments else {
            logger.warning("live diarization: window produced no usable result")
            return []
        }

        let spans = stitch(segments: segments, windowStart: windowStart)
        let roundTripMS = Int(((ContinuousClock.now - started).seconds * 1000)
            .rounded())
        // `.debug`: one line per window (~every 5 s) — a performance observable.
        logger.debug("""
            live diarization: window \(windowCounter) done — \
            \(roundTripMS) ms on ANE, \(spans.count) span(s)
            """)
        return spans
    }
```

- [ ] **Step 5: Replace `stitch(result:windowStart:)` with `stitch(segments:windowStart:)`**

Delete the existing `private func stitch(result:windowStart:)` (the one building `embeddingByLabel` / `keyByRawLabel`) and replace it with:

```swift
    /// Turn one window's per-segment embeddings into stable-keyed,
    /// recording-absolute `LiveSpeakerSpan`s. Segments at least
    /// `minReliableSegment` long drive the bank (match-or-create + refine);
    /// shorter ones are labelled by a read-only nearest match and dropped when
    /// they match nothing — they never create a speaker or update a centroid
    /// (D40 spike: short-segment embeddings are noisy). `internal` so the
    /// stitch logic is unit-testable without CoreML models.
    func stitch(
        segments: [DiarizerEngine.WindowSegmentEmbedding],
        windowStart: Duration
    ) -> [LiveSpeakerSpan] {
        var out: [LiveSpeakerSpan] = []
        for segment in segments {
            guard !segment.vector.isEmpty else { continue }
            let key: String?
            if (segment.end - segment.start) >= Self.minReliableSegment {
                key = stitchKey(for: segment.vector)        // match-or-create + refine
            } else {
                key = nearestKey(for: segment.vector)       // read-only; may be nil
            }
            guard let key else { continue }
            out.append(LiveSpeakerSpan(
                provisionalKey: key,
                start: windowStart + segment.start,
                end: windowStart + segment.end,
                embedding: segment.vector))
        }
        return out
    }
```

- [ ] **Step 6: Add the read-only `nearestKey(for:)` helper**

Immediately after `stitchKey(for:)`:

```swift
    /// Best existing live speaker for an embedding (cosine ≥ threshold), or
    /// `nil`. Read-only — never creates a speaker or refines a centroid. Used
    /// to label sub-`minReliableSegment` segments without letting their noisy
    /// embeddings spawn ghosts or poison the bank.
    private func nearestKey(for embedding: [Float]) -> String? {
        var bestIndex = -1
        var bestScore = Self.stitchThreshold
        for (i, speaker) in liveSpeakers.enumerated() {
            let score = Centroid.cosineSimilarity(speaker.centroid, embedding)
            if score >= bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        return bestIndex >= 0 ? liveSpeakers[bestIndex].key : nil
    }
```

- [ ] **Step 7: Run the unit tests to verify they pass**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter LiveDiarizerStitch`
Expected: `✔ Test run with 4 tests in 1 suite passed`.

- [ ] **Step 8: Commit**

```bash
git add Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift Tests/UnitTests/LiveDiarizerStitchTests.swift
git commit -m "fix(live): stitch per-segment embeddings, bypass per-window VBx (D40)"
```

---

## Task 2: E2E regression — live windowed pass separates two speakers

Lock in the fix end-to-end against the real CoreML models, on the committed two-speaker fixture, driving the production window geometry (10 s window / 5 s step).

**Files:**
- Modify: `Tests/PipelineTests/DiarizationE2ETests.swift`

- [ ] **Step 1: Add the failing regression test**

Inside the `DiarizationE2ETests` struct (it already has `fixtureURL(_:)` and uses `DiarizerTestEngine.shared()`), add:

```swift
    /// D40 live-separation regression: the windowed live path (per-segment
    /// embeddings + online bank) must surface BOTH voices in the 24 s
    /// two-speaker clip. The bug was the live pass collapsing them to one
    /// provisional key because per-window VBx under-separates on short windows.
    /// Drives `LiveDiarizer.diarizeWindow` over 10 s windows / 5 s step — the
    /// production geometry from `StreamingPipeline.Configuration`.
    @Test func liveWindowedPassSeparatesTwoSpeakers() async throws {
        let engine = try await DiarizerTestEngine.shared()
        let wav = try WAVReader(contentsOf: fixtureURL("two-speakers-alternating"))
        let diarizer = LiveDiarizer(engine: engine)

        let windowSamples = 10 * wav.sampleRate
        let stepSamples = 5 * wav.sampleRate
        var keys = Set<String>()
        var start = 0
        while start < wav.samples.count {
            let end = min(start + windowSamples, wav.samples.count)
            let window = Array(wav.samples[start..<end])
            let windowStart = Duration.milliseconds(start * 1000 / wav.sampleRate)
            let spans = await diarizer.diarizeWindow(
                samples: window, windowStart: windowStart)
            for span in spans { keys.insert(span.provisionalKey) }
            if end == wav.samples.count { break }
            start += stepSamples
        }
        #expect(keys.count >= 2, "live windowed pass collapsed speakers: \(keys)")
    }
```

- [ ] **Step 2: Run it**

Run (bare, `dangerouslyDisableSandbox: true`): `swift test --filter DiarizationE2E`
Expected: all `DiarizationE2E` tests pass, including `liveWindowedPassSeparatesTwoSpeakers` (`keys.count >= 2`). First run downloads the ~21 MB diarizer model if not cached (see CLAUDE.md narrow-filter notes).

- [ ] **Step 3: Commit**

```bash
git add Tests/PipelineTests/DiarizationE2ETests.swift
git commit -m "test(live): E2E regression — windowed live pass separates two speakers (D40)"
```

---

## Task 3: Refresh the threshold doc comment

The spike validated `stitchThreshold = 0.45` for per-segment embeddings (same-speaker ≈ 0.75–0.82, cross-speaker ≈ 0.29–0.35); no value change. Update the comment so it documents the per-segment regime rather than the retired per-cluster one.

**Files:**
- Modify: `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift` (the `stitchThreshold` doc comment, ~line 92)

- [ ] **Step 1: Update the comment**

Replace the `stitchThreshold` doc comment with:

```swift
    /// Cosine-similarity threshold for stitching a window segment to an
    /// existing live speaker. Above → same speaker; below → a new `Them #N`.
    /// Calibrated for the WeSpeaker space on per-segment embeddings (D40
    /// spike, 2026-06-15): same-speaker cosine ≈ 0.75–0.82, cross-speaker
    /// ≈ 0.29–0.35, so 0.45 sits cleanly in the gap.
```

- [ ] **Step 2: Build to confirm it compiles**

Run (bare, `dangerouslyDisableSandbox: true`): `swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift
git commit -m "docs(live): stitch-threshold comment reflects per-segment calibration (D40)"
```

---

## Task 4: Remove the throwaway spike test

The committed E2E regression (Task 2) replaces the spike, which depends on a local recording path that exists only on the author's machine.

**Files:**
- Delete: `Tests/PipelineTests/DiarizationSpikeTests.swift`

- [ ] **Step 1: Delete the file**

```bash
git rm Tests/PipelineTests/DiarizationSpikeTests.swift
```

- [ ] **Step 2: Confirm the suite still builds and the diarization filters are green**

Run each, bare, `dangerouslyDisableSandbox: true`:
- `swift test --filter LiveDiarizerStitch` → expected: 4 tests pass
- `swift test --filter DiarizationE2E` → expected: all pass
- `swift test --filter Streaming` → expected: all pass (no reference to the deleted spike or the removed `stitch(result:)`)

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore(test): drop the D40 diarization spike (E2E regression replaces it)"
```

---

## Verification (run before declaring done)

Per CLAUDE.md, verify with the narrow filters (bare commands, `dangerouslyDisableSandbox: true`) — never `--filter PipelineTests` broadly:

- [ ] `swift build` → `Build complete!`
- [ ] `swift test --filter LiveDiarizerStitch` → 4 pass
- [ ] `swift test --filter DiarizationE2E` → all pass
- [ ] `swift test --filter Streaming` → all pass
- [ ] `swift test --filter UnitTests` → all pass

If any test fails — even one you think is unrelated — it is yours per the project's no-failing-tests rule: fix the cause, gate it explicitly, or escalate.

## Out of scope (do not touch)

- Offline refine path (`Diarizer`, `engine.diarize(wavPath:)`) — VBx is correct with whole-file evidence.
- Speaker library, `metadata.json`, events, the WeSpeaker embedding space / model revision (R29 preserved — same engine, same embeddings).
- Window geometry (`diarizationWindow = 10 s`, `diarizationStep = 5 s`) — the spike showed segmentation surfaces both voices at 10 s, so the window need not grow.

## Follow-ups (not in this plan — YAGNI until measured)

- Duration-weighted running mean (longer segments weighted more) — only if over-/under-merge shows up in real recordings.
- Skipping VBx for the live path to save compute — current cost is negligible (one chunk per window); revisit only if profiling says so.
