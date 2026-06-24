# PT-P3-E3 · Operational Hardening — Completion Record

**Status:** Frozen · **Closed:** 2026-05-20

## What was built

`EventWriter.append` now takes an exclusive advisory file lock on the daily event file, so appends
from the capture, menubar, and CLI processes can no longer interleave a clobbered line; operational
stderr/log paths are redacted (`PathRedactor`). A refinement job builds one recognizer and reuses it
across all regions (`SharedTranscriber`) — per-region construction had been re-initializing the GPU
pipeline and dominating refine time. The queued refine reached parity with the one-shot path: speaker
reconciliation, the full refinement event sequence, real paused-state handling, and propagated
(non-swallowed) errors with a persisted last-error.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P3-R4** — `Sources/PulsarTraceEngine/Events/EventWriter.swift`; `Support/PathRedactor.swift`
- **PT-P3-R3 (parity/perf)** — `Sources/PulsarTraceEngine/Refinement/Jobs/SharedTranscriber.swift`, `ResumableRefiner.swift`

## To flow into the product layer

- Update the Events Log component with the cross-process advisory lock; update the Refinement Job
  Queue with per-job recognizer reuse.
- Mint product requirement PT-R96 (cross-process event-log integrity).
