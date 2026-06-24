# PT-P4-E1 · Streaming Cadence & Language — Specification

**Status:** Frozen · **Opened:** 2026-05-29 · **Closed:** 2026-05-31

## Intent

Tune the live pass: lengthen the decode cadence to free the recognizer, and restrict per-window
language detection to a configured allow-list (PT-P4-R1). Touches Streaming Transcription (PT-C12)
and the Menubar settings (PT-C16).

## Acceptance criteria

- Live decode load is roughly halved while live lag stays within bound.
- Live language detection only selects among the configured languages, set from a settings picker.

## Tasks

- PT-P4-E1-T1 — Lengthen decode step/window
- PT-P4-E1-T2 — Per-window language detection over an allow-list + settings picker
