# PT-P1-E4 · Refinement Pipeline — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Deliver the post-recording refinement pass that produces the authoritative transcript (PT-P1-R6):
re-transcribe at refinement quality, diarize globally (PT-P1-E3), merge by timestamp, write the
final transcript atomically with a metadata sidecar, and drive it from the command line. This is the
v0.1 ship point — the first end-to-end user-facing output.

## Acceptance criteria

- Refining a recording produces a final transcript plus a metadata sidecar.
- The write is atomic — an interrupted refine leaves no partial transcript; the prior input is
  preserved as a backup.
- A no-speech recording yields a valid empty transcript; a failure exits non-zero and emits a
  failure event.

## Tasks

- PT-P1-E4-T1 — Refinement pipeline: re-transcribe + global diarize + timestamp merge
- PT-P1-E4-T2 — Recording-folder input dispatch (bare WAV → sibling folder)
- PT-P1-E4-T3 — Atomic final-transcript + metadata sidecar writes with backups and markers
- PT-P1-E4-T4 — `refine` CLI subcommand with progress and lifecycle events
