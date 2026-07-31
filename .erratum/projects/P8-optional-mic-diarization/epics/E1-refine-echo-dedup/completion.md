# PT-P8-E1 · Refine-side mic-echo dedup — Completion Record

**Status:** Frozen · **Closed:** 2026-07-29

## What was built

`TranscriptAssembly.dedupedMicSegments(_:against:)` (commit c312164) — the refine merge now runs
every mic segment through the same `MicEchoDedup` value type the live pass uses (0.5 similarity, ±5
s window; the comparison is strictly-greater, matching `MicEchoDedup.isMicEcho`, not the spec
draft's `≥`) before a segment can earn a `You` line. The filter sits inside the shared
`mergeStreams`, so both refine paths — CLI `RefinementPipeline` and the queue's `ResumableRefiner`
via `assembleAndWrite` — inherit it, as does every later P8 stage (owner-profile learning selects
over the deduped set; mic attribution labels it).

Tests: `TranscriptAssemblyDedupTests` (echo dropped / distinct kept / outside-window kept /
no-system passthrough) and `ResumableRefinerDedupTests`, a stub-scripted queue-path proof that a mic
duplicate never reaches `final.md`. The queue test was bite-checked: with the filter locally
reverted it fails with the echo line present, confirming the queue path genuinely funnels through
the shared merge.

## Deltas from the task skeleton

- **T2's fixture helper was insufficient:** `FixtureRecording.minimal` writes only
  `audio-system.wav`, so the refiner would never transcribe a mic stream and the test would pass
  vacuously. A local `writePairedFixture` writes both WAVs via `WAVWriter`.
- The `DiarizationResult` stub omits `modelRevision` (the initializer defaults it to `""`), matching
  the established `ResumableRefinerTests` stub idiom rather than the draft.

## Requirements satisfied

- **PT-P8-R11** (refine half) — mic-side duplicates of system speech are dropped in both refine
  paths, before attribution and before owner-profile learning. The live half is today's unchanged
  `MicEchoDedup` behavior in the streaming layer.

## To flow into the product layer

At close-out, PT-P8-R11's supersession of PT-R19 records the corrected drop direction (mic-side copy
dropped; system stream authoritative) and extends coverage to the refine pass; `implemented_by`
gains `TranscriptAssembly.dedupedMicSegments` beside the existing `MicEchoDedup`.
