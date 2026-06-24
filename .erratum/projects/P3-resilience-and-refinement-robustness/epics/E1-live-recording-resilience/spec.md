# PT-P3-E1 · Live-Recording Resilience — Specification

**Status:** Frozen · **Opened:** 2026-05-18 · **Closed:** 2026-05-18

## Intent

Make the recording itself durable: crash-safe incremental audio (PT-P3-R1) and automatic recovery
from a stalled capture stream (PT-P3-R2). Touches the Capture Daemon (PT-C15) and the live recording
path (PT-C12/PT-C14).

## Acceptance criteria

- A hard kill mid-recording leaves a valid, refine-able audio file missing at most ~1 s.
- A silently stalled capture stream is detected and its engine rebuilt, annotated as a pause/resume,
  without ending the recording.
- The live diarizer is off the recording-critical path, so a stuck diarize cannot stall the WAV.

## Tasks

- PT-P3-E1-T1 — Incremental WAV writer with live header re-patching
- PT-P3-E1-T2 — Per-engine frame watchdog + backoff auto-restart via pause/resume
- PT-P3-E1-T3 — Move the live diarizer off the run-loop critical path (bounded, gated)
