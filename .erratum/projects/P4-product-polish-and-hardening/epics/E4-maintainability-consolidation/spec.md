# PT-P4-E4 · Maintainability Consolidation — Specification

**Status:** Frozen · **Opened:** 2026-06-09 · **Closed:** 2026-06-10

## Intent

A pure-architecture refactor with no behaviour change: unify the duplicated transcriber cores, split
the live runner's several responsibilities into focused types, extract transcript assembly, and
remove layering leaks. Introduces no product requirement; it edits components only — Transcription /
IPC (PT-C2, PT-C19), the live pipeline (PT-C12, PT-C18), and the Refinement Pipeline (PT-C4).

## Acceptance criteria

- The live and refine transcriber paths share one core; no duplicated remote-transcriber logic.
- The live runner's responsibilities are separated into focused types with no behaviour change.
- The full test suite stays green across the refactor.

## Tasks

- PT-P4-E4-T1 — Unify remote transcriber cores
- PT-P4-E4-T2 — Split the live runner; extract a live sink and diarization state
- PT-P4-E4-T3 — Extract transcript assembly; fix layering leaks
