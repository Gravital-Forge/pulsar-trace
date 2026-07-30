# PT-P8-E4 · Live-pass mic diarization — Specification

**Status:** Frozen · **Opened:** 2026-07-29 · **Closed:** 2026-07-29

## Intent

Implements PT-P8-R13 and the live half of PT-P8-R1; touches components PT-C12/PT-C13 (streaming +
live diarization), PT-C14 (live markdown), PT-C15/PT-C9 boundary (engine flags via `RecordPlan`).
With the recording's stamp on, the live pass runs a second windowed `LiveDiarizer` over mic frames
with a parameterized provisional-label family (`Guest` / `Guest #2`, distinct from the system
stream's `Them` — PT-P8-D11). Mic utterance labels resolve: owner-profile match (read-only) →
`You`; known library speaker (read-only, existing `?` semantics) → name; else `Guest`-family
provisional. The live pass stays read-only against library and profile; `live.md` stays
append-only; with the stamp off, byte-identical behavior to today. The engine learns the stamp by
reading `options.json` from the output folder at start (the sidecar is written by the record
surfaces in E6; the engine additionally honors a `--diarize-mic` flag so the engine is testable
before E6 lands).

## Acceptance criteria

- Stamp/flag off ⇒ `live.md` byte-identical to today for the same input (mic lines all `You`).
- Stamp/flag on ⇒ mic lines carry `You` (owner match), library names, or `Guest`-family labels
  with the existing `?` pre-reconciliation semantics; system-stream labels unaffected (`Them`
  family intact).
- Library and owner-profile files are byte-identical after a live pass (read-only invariant).
- No cross-stream stitching: mic and system `LiveDiarizer` instances are independent.
- `swift test --filter Streaming` and `--filter LiveRunner` green.

## Tasks

- PT-P8-E4-T1 — Parameterize `LiveDiarizer`'s provisional label family (`Them` → configurable)
- PT-P8-E4-T2 — Mic label resolution in `LiveRunner`/`LiveSink` (owner → library → `Guest`)
- PT-P8-E4-T3 — Second windowed diarizer in `StreamingPipeline` + engine/`RecordPlan` flag wiring
- PT-P8-E4-T4 — Live end-to-end: scripted-diarizer test + fixture run
