# PT-P3-E2 · Refinement Job Queue — Completion Record

**Status:** Frozen · **Closed:** 2026-05-20

## What was built

`RefinementJobQueue` is a single-worker FIFO actor over `RefinementJob` / `RefinementJobState` value
types, persisted as JSONL by `RefinementJobStore` (with terminal pruning). `ResumableRefiner` runs
the refine loop with per-voice-activity-region checkpointing to `RefinementProgress`, waiting on a
`PauseGate` between regions; a recording start pauses the gate and cancels the in-flight
diarization, requeuing that region (a cancelled diarize is retryable, not a failure). The menubar's
`RecordingViewModel` now enqueues auto-refine and returns to idle immediately; manual re-refine and
crash-recovery feed the same queue. `RefinementJobQueueViewModel` exposes the queue to the UI by
polling a snapshot at a fixed short interval, surfacing running / queued / recent jobs with
progress.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P3-R3** — `Sources/PulsarTraceEngine/Refinement/Jobs/` — `RefinementJobQueue.swift`,
  `ResumableRefiner.swift`, `RefinementJobStore.swift`, `RefinementProgress.swift`,
  `PauseGate.swift`, `RefinementJob.swift`, `RefinementJobState.swift`;
  `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift`

## To flow into the product layer

- Mint a Refinement Job Queue component; note that the menubar drives refinement through it while
  the CLI keeps the direct one-shot path.
- Mint product requirements PT-R94 (non-blocking queued refinement), PT-R95 (refinement yields to
  recording and resumes from checkpoint).
