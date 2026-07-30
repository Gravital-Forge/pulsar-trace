# PT-P8-E1 · Refine-side mic-echo dedup — Specification

**Status:** Frozen · **Opened:** 2026-07-29 · **Closed:** 2026-07-29

## Intent

Implements PT-P8-R11; touches components PT-C4 (Refinement Pipeline) and PT-C11 (Transcript
Output). The live pass already drops mic utterances that duplicate system-stream speech
(`MicEchoDedup`, PT-C14), but the refine pass re-admits every mic segment unconditionally
(`TranscriptAssembly.mergeStreams` appends all mic segments as `You`). This epic applies the same
`MicEchoDedup` value type inside the shared refine merge, so both refine paths (CLI
`RefinementPipeline` and the queue's `ResumableRefiner`, which both funnel through
`TranscriptAssembly`) drop mic-side duplicates before attribution. Mode-independent: this is a
correctness fix that stands on its own, and later epics (owner-profile learning in E2, mic cluster
attribution in E3) build on the deduped segment set.

## Acceptance criteria

- A mic segment whose text duplicates a system segment (≥ 0.5 similarity, ±5 s window — the
  existing `MicEchoDedup` constants) does not appear in `final.md` and does not contribute a `You`
  line, in both refine paths.
- Non-duplicate mic segments are untouched; a recording with no system stream is unchanged.
- All existing suites that exercise the merge stay green (`swift test --filter
  TranscriptAssemblyMergeTests`, `--filter RefinementPipelineTests`, `--filter ResumableRefiner`).

## Tasks

- PT-P8-E1-T1 — Dedup filter inside `TranscriptAssembly.mergeStreams` (unit-tested pure logic)
- PT-P8-E1-T2 — End-to-end verification over the paired mic+system fixture, both refine paths
