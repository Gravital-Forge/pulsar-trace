# PT-P2-E5 · Capture & Transcript Correctness — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Harden the offline pass and capture against the failures the first real recordings surfaced: robust
offline decoding free of silence-repetition, correct cross-turn ordering, and a safe
hallucination filter (PT-P2-R13), plus the device-format downmix fix that restored mic capture
(hardening PT-P2-R4). Touches the Transcription Engine and Refinement Pipeline (PT-C2, PT-C4) and the
Capture Daemon (PT-C-capture).

## Acceptance criteria

- A recording with long silences yields no repetition loops; multi-turn audio keeps correct speaker
  ordering.
- Stock-phrase hallucinations are dropped only when an objective silence signal agrees.
- A layout-less stereo device format downmixes correctly so mic capture is not silent.

## Tasks

- PT-P2-E5-T1 — Non-zero-temperature decode ladder + per-voice-activity-region decoding
- PT-P2-E5-T2 — Phrase-plus-confidence hallucination filter
- PT-P2-E5-T3 — Device-format downmix repair for layout-less stereo capture
