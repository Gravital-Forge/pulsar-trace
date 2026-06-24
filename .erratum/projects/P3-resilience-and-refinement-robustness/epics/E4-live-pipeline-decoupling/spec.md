# PT-P3-E4 · Live-Pipeline Decoupling & Wedge Recovery — Specification

**Status:** Frozen · **Opened:** 2026-05-22 · **Closed:** 2026-05-29

## Intent

Isolate the durable recording from a wedged transcription decode (PT-P3-R5): split the live run so
the recognizer can never stall the recording, then make a wedged decode actually recoverable by
moving inference into a kill-able subprocess. Touches the live pipeline (PT-C12) and the
transcription path (PT-C2).

## Acceptance criteria

- A deliberately wedged decode leaves the WAV, the live transcript, and the recording intact.
- The recording-safe path never calls the recognizer directly; decode work is bounded and offloaded.
- A wedged decode is force-killed and the recognizer respawned without taking down the engine.

## Tasks

- PT-P3-E4-T1 — Split the live run into a recording-safe drain + a best-effort decode worker
- PT-P3-E4-T2 — Bounded drop-oldest frame queue; decode watchdog + abort token
- PT-P3-E4-T3 — Out-of-process recognizer over IPC with parent-side kill/respawn
