# PT-P1-E5 · Speaker Library — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Carry speaker identity across recordings (PT-P1-R7): a durable speaker store with running-mean
centroids, reconciliation of a recording's speakers against the store, stable speaker IDs,
concurrent-safe journaling, recoverable deletes, and command-line management. Consumes the
embeddings from PT-P1-E3 and is written by the refinement pass from PT-P1-E4. Completes the v0.1
milestone.

## Acceptance criteria

- A returning speaker in a second recording is matched to the same stable ID and name.
- Centroids update by a count-weighted running mean; the store survives concurrent reader/writer.
- A deleted speaker is recoverable within the undo window.

## Tasks

- PT-P1-E5-T1 — SQLite speaker store (schema, WAL, backup/restore)
- PT-P1-E5-T2 — Centroid running-mean update + reconciliation against the store
- PT-P1-E5-T3 — Stable speaker IDs and soft-delete with undo
- PT-P1-E5-T4 — `speakers` CLI (list / rename / merge / delete)
