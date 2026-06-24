# PT-P1-E3 · Offline Diarization — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Diarize the system stream offline into speaker turns with per-speaker embeddings, never diarizing
the microphone stream (PT-P1-R5), and do so without any off-device telemetry (PT-P1-R11). Provides
the speaker turns the refinement pass merges against the transcript from PT-P1-E2.

## Acceptance criteria

- A two-party recording yields distinct speaker turns over the system stream.
- Microphone-origin speech is always attributed to the local speaker, never diarized.
- Results are deterministic given seeded inputs; the diarization library emits no telemetry.

## Tasks

- PT-P1-E3-T1 — Diarization subprocess (model in, turns + embeddings out) with a typed JSON contract
- PT-P1-E3-T2 — Transcript × turns merge by dominant overlap
- PT-P1-E3-T3 — Disable the library's telemetry exporter; add a model-revision identifier
