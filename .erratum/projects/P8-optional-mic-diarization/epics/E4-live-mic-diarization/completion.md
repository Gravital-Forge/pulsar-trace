# PT-P8-E4 · Live-pass mic diarization — Completion Record

**Status:** Frozen · **Closed:** 2026-07-29

## What was built

Commit ad74b42:

- **`LiveDiarizer.labelFamily`** — init parameter, default `"Them"` (zero behavior change);
  `provisionalKey` became instance-derived, so a mic instance mints `Guest`, `Guest #2`, …
  (PT-P8-D11).
- **`LiveRunner.resolveMicLabel`** — the mic twin of `resolveSystemLabel`: dominant span over the
  utterance range (shared `dominantSpan` helper mirroring `DiarState.dominantKey`'s accumulation and
  tie-break, returning a representative span so the caller has its embedding) → owner-profile match
  (`You`, no `?` — as strong as a library match; revision-guarded against the live model's revision)
  → read-only library `bestMatch` (`name?`, the system twin's `?` rule) → provisional `Guest`-family
  key + `?` → neutral `Speaker?` on no coverage. Pure and directly unit-tested, including a
  revision-mismatch case.
- **Independent mic diarization state in the run loop:** own `DiarBufferManager`, `DiarState`, and
  `DiarGate` with the system stream's 10 s/5 s geometry; windows run in a detached task off the
  frame loop's critical path (the Fix B posture) with at most one in flight; teardown drains the mic
  gate with the same 2 s bound. No cross-stream stitching — nothing is shared with the system
  instance. `LiveSink.appendMicUtterance` gained an optional `label:`; echo dedup still runs first,
  and `nil` keeps the literal `You`, so mode-off is byte-identical.
- **Wiring:** `StreamingPipeline.Configuration` gained `micRawDiarizer` and `ownerProfile` — a
  **value snapshot**, read once at start (no per-utterance actor hop; live pass stays read-only
  against the profile). Engine `--live` enables the mic diarizer on `--diarize-mic` OR the
  `options.json` stamp; one resident `DiarizerEngine` is wrapped by two adapters. `RecordPlan.make`
  gained `diarizeMic: Bool = false` → appends `--diarize-mic`.
- **Two-voice mic fixture** (`Tests/Fixtures/audio/mic-two-speakers.wav`, 53.8 s): PCM-frame
  concatenation of `single-speaker-30s.wav` + `two-speakers-alternating.wav` by a committed
  Python-stdlib generator script (no new tool dependency). Real diarization yields two clusters.
  Live E2E (`StreamingPipelineMicDiarizationTests`): scripted mic diarizer + seeded snapshot ⇒
  `live.md` carries `You` and a `Guest`-family label with no profile file appearing on disk;
  mode-off run carries no `Guest`. E3-T4's deferred guest assertion closed against the new fixture
  (`MicDiarizedRefineTests` now asserts a mic `Unknown #N` row).

## Deltas from the task skeleton

- **Library-matched live mic labels carry the `?` suffix** (`Priya?`). The draft test showed a bare
  name but instructed matching the system twin's rule; the system twin (and PT-P8-R13's "existing
  `?` pre-reconciliation semantics") say suffixed.
- The system label path resolves via `DiarState.dominantKey` + `centroids()` (key-level); the mic
  path needs the dominant *embedding* for the owner match, hence `dominantSpan` + `allSpans()`
  rather than a key-only twin.
- T2/T3's configuration fields landed together (the runner plumbing depends on them).

## Empirical findings worth keeping

- `DiarizerEngine.diarize(samples:)` is stateless per call; per-stream stitching state lives in each
  `LiveDiarizer`. Two adapters over one engine is the correct shape — no second model load, no extra
  ANE memory.
- `ScriptedRawDiarizer` is duplicated between the UnitTests and PipelineTests targets (no shared
  test-support target exists). Candidate consolidation if a third copy ever appears.

## Requirements satisfied

- **PT-P8-R13** — stamp-on live mic diarization with owner/library/`Guest` resolution; stamp-off
  byte-identical; library and profile read-only; independent label spaces.
- **PT-P8-R1** (live half) — both passes now cover the mode.

## To flow into the product layer

At close-out: the `live.md` contract documents the `Guest` provisional family beside `Them`
(PT-P8-R10's doc half); `RecordPlan`'s `--diarize-mic` and the engine's stamp read become
`implemented_by` anchors for R13.
