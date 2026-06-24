# PT-P1-E1 · Foundations — Specification

**Status:** Frozen · **Opened:** 2026-05-15 · **Closed:** 2026-05-16

## Intent

Establish the package skeleton and the cross-cutting seams every later capability depends on: the
pluggable audio-source abstraction (PT-P1-R1), the append-only events log (PT-P1-R8), content-safe
operational logging (PT-P1-R9), the deterministic layered test strategy (PT-P1-R10), and the
baseline constraints of open-source-only dependencies (PT-P1-R12) and versioned public contracts
(PT-P1-R13). No domain capability ships here — this epic is the ground the others stand on.

## Acceptance criteria

- One audio-source protocol with fixture, pipe, and socket implementations, each terminating
  cleanly; the same downstream code runs over all three.
- An events log that appends one enveloped JSON record per significant operation, with daily
  rotation and retention, carrying no content.
- Operational logs that pass a content-leak scan and capture subprocess stderr.
- Unit, pipeline, and Python test layers runnable independently and reproducibly.

## Tasks

- PT-P1-E1-T1 — Audio frame model + source protocol and three implementations
- PT-P1-E1-T2 — Logging backends (file + system log), rotation, content-leak scan
- PT-P1-E1-T3 — Events envelope, registry, writer, rotation
- PT-P1-E1-T4 — IPC frame/control protocol definitions
- PT-P1-E1-T5 — Test targets and fixtures
