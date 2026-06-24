# PT-P3 · Resilience & Refinement Robustness — Project PRD

**Status:** Frozen · **Opened:** 2026-05-18 · **Closed:** 2026-05-29

## Scope

This project makes recording and refinement survive real-world failure. It makes the recording itself
durable (audio persisted incrementally; stalled capture detected and recovered), turns refinement
into a non-blocking, resumable, single-worker queue so back-to-back meetings never block on a
still-running refine, hardens the cross-process event log against interleaved writes, and isolates the
durable recording from a wedged transcription decode.

It changes how the existing capabilities behave under stress rather than adding new user-facing
surfaces; the recognition and diarization engines are unchanged in kind. Requirements introduced here
are new robustness guarantees the product layer did not previously state.

## Project Requirements

All change-types are **Introduce**.

### PT-P3-R1 · Functional · Introduce — Crash-safe incremental recording

Recorded audio is written to disk incrementally so an abnormal end (crash or force-kill) loses at
most about one second of the tail, and the on-disk file is always a valid, refine-able recording.

*Introduces:* PT-R92
*Acceptance:* a hard kill mid-recording leaves a valid audio file missing at most ~1 s.

### PT-P3-R2 · Functional · Introduce — Capture stall recovery

A silently stalled capture stream is detected and its engine rebuilt automatically, surfaced as a
pause/resume, without ending the recording.

*Introduces:* PT-R93
*Acceptance:* a stalled capture stream recovers automatically and the recording continues.

### PT-P3-R3 · Functional · Introduce — Non-blocking, resumable refinement

Refinement runs through a single-worker queue whose state persists across restarts; a finished
recording does not block the next, and starting a recording pauses an in-flight refine, which resumes
from its on-disk checkpoint afterward.

*Introduces:* PT-R94, PT-R95
*Acceptance:* a second recording starts immediately while a refine is queued or paused, and the refine
resumes from its checkpoint.

### PT-P3-R4 · Technical · Introduce — Cross-process event-log integrity

Concurrent appends to the shared event log are serialized so records never interleave.

*Introduces:* PT-R96
*Acceptance:* concurrent writers never produce a torn or interleaved line.

### PT-P3-R5 · Functional · Introduce — Recording isolated from decode hangs

A stuck transcription decode cannot stall or lose the recording, the live transcript, or the audio
file; a wedged decode is recoverable.

*Introduces:* PT-R97
*Acceptance:* a deliberately wedged decode leaves the WAV, live transcript, and recording intact.
