# PT-P1-E2 · Offline Transcription — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Transcribe a complete audio stream into a timestamped Markdown transcript (PT-P1-R2), acquire the
recognition model safely (PT-P1-R3), and persist audio in the canonical storage format (PT-P1-R4).
Builds on the audio sources from PT-P1-E1; emits the transcript document the refinement pass will
later author authoritatively.

## Acceptance criteria

- Transcribing a fixture produces a Markdown transcript matching a committed snapshot,
  deterministically over repeated runs.
- A model download resumes after interruption and is rejected on hash mismatch.
- Stored audio is 16 kHz mono Int16 WAV and re-readable downstream.

## Tasks

- PT-P1-E2-T1 — Resident recognizer over a vendored native engine (C interop)
- PT-P1-E2-T2 — Model store: resumable download + content-hash verification
- PT-P1-E2-T3 — Whole-stream offline transcription pipeline + transcript document format
- PT-P1-E2-T4 — Canonical WAV writer/reader
