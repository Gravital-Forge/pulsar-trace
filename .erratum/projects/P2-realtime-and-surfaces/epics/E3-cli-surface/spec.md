# PT-P2-E3 · CLI Surface — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Complete the operator command line: `record` orchestration (PT-P2-R7), a `doctor` with an audio
self-test (PT-P2-R8), `events tail` and `install-cli` (PT-P2-R9), and a maintained release
smoke-test checklist (PT-P2-R14). Reuses the engine orchestrator (PT-C9) and drives capture and the
live/refine passes.

## Acceptance criteria

- `record` produces a recording folder with a final transcript, for a duration or until interrupted.
- `doctor` reports actionable status and exits non-zero on any hard failure; `--capture-test`
  verifies a tone round-trip.
- `events tail` streams today's events with an optional, validated type filter; `install-cli`
  symlinks with consent and uninstalls.

## Tasks

- PT-P2-E3-T1 — `record` via the engine orchestrator (spawn capture + engine, then refine)
- PT-P2-E3-T2 — `doctor` checks + tone-based capture self-test
- PT-P2-E3-T3 — `events tail` with type filter; `install-cli` symlink/uninstall
- PT-P2-E3-T4 — Release smoke-test checklist (operational artifact, kept outside this directory)
