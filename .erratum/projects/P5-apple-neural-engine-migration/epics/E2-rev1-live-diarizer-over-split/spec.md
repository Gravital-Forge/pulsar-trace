# PT-P5-E2-rev1 · Live-Diarizer Over-Split — Specification

**Status:** Frozen · **Opened:** 2026-06-15 · **Closed:** 2026-06-16

**revises:** PT-P5-E2

## Intent

Investigate and cure an apparent per-window **over-split** in the live diarizer landed by PT-P5-E2,
where a single speaker fragments into 2–3 provisional keys and the R18 library lookup mis-names each
fragment. This is a tuning revision of the live diarization in PT-P5-E2 (component PT-C13 / the
`DiarizerEngine` clustering); it proposes **no new product requirement** — the live-diarization
intent (PT-R15/R16/R18) is unchanged.

## Acceptance criteria

- A real two-speaker recording yields the correct number of live provisional keys without splitting
  one speaker across several, while the committed fixtures keep their existing key counts.

## Tasks

- PT-P5-E2-rev1-T1 — Split `DiarizerEngine` into a refine manager (default
  `clustering.threshold = 0.6`) and a live manager with a raised AHC threshold
  (`liveClusteringThreshold = 1.05`).
- PT-P5-E2-rev1-T2 — Calibrate the threshold and add live-path key-count guard tests.
- PT-P5-E2-rev1-T3 — Revert: restore a single shared manager at the default threshold (the
  experiment did not address the real failure).
