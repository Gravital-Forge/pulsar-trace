# PT-P3-E3 · Operational Hardening — Specification

**Status:** Frozen · **Opened:** 2026-05-20 · **Closed:** 2026-05-20

## Intent

Close the gaps the queue path exposed and harden cross-process operation: serialize event-log appends
across processes (PT-P3-R4), reuse one recognizer per refinement job for usable refine performance,
and bring the queued refine to parity with the one-shot path (speaker reconciliation, real events,
no swallowed errors). Touches the Events Log (PT-C6) and the Refinement Pipeline / queue (PT-C4,
PT-C17).

## Acceptance criteria

- Concurrent event-log appends from different processes never interleave.
- A refinement job constructs the recognizer once and reuses it across regions.
- The queued refine reconciles speakers, emits the same events, and surfaces errors like the one-shot
  path.

## Tasks

- PT-P3-E3-T1 — Exclusive advisory lock around event-log appends; path redaction
- PT-P3-E3-T2 — Shared per-job recognizer reuse across regions
- PT-P3-E3-T3 — Queue/one-shot parity: speaker reconcile, events, error propagation
