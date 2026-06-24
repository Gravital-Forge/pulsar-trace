# PT-P3-E2 · Refinement Job Queue — Specification

**Status:** Frozen · **Opened:** 2026-05-19 · **Closed:** 2026-05-20

## Intent

Turn refinement into a non-blocking, resumable, single-worker queue (PT-P3-R3): a finished recording
returns to idle immediately, and starting a recording pauses an in-flight refine that later resumes
from its on-disk checkpoint. Reworks how the Refinement Pipeline (PT-C4) is driven by the menubar;
the CLI keeps its direct one-shot refiner.

## Acceptance criteria

- A finished recording enqueues its refine and returns to idle; a second recording can start at once.
- A recording start pauses the queue (and the in-flight diarization), which resumes from checkpoint
  afterward.
- Queue state survives a restart; the queue UI reflects running/queued/recent jobs.

## Tasks

- PT-P3-E2-T1 — Job + job-state value types; JSONL-persisted job store
- PT-P3-E2-T2 — Per-region refinement checkpoint schema; resumable refiner
- PT-P3-E2-T3 — Single-worker queue actor with pause/resume and cancel
- PT-P3-E2-T4 — Pause-gate primitive; cancel-and-requeue of in-flight diarization
- PT-P3-E2-T5 — Queue view model (snapshot polling) and recordings-list integration
