# PT-P6-E4 · Speaker Write Tools — Specification

**Status:** Open · **Opened:** 2026-06-26

## Intent

Add the nine speaker-management tools — `rename_speaker`, `merge_speakers`, `split_speaker`,
`unmerge_speakers`, `unsplit_speaker`, `delete_speaker`, `undelete_speaker`, `delist_speaker`,
`undelist_speaker` — each a thin one-to-one wrapper over the Speaker Edit Service (PT-P6-E1), so an
agent edit drives the retroactive `final.md` rewrite and the paired events exactly as the in-app
editor (PT-R90). A speaker-library mutation requested while a recording is in progress is refused,
keeping the library read-only during capture (PT-R32). Implements PT-P6-R5. Extends the MCP Server
(PT-C22); uses the Speaker Edit Service (PT-P6-E1) and the live-recording status from the Menubar
(PT-C16). Depends on PT-P6-E2 and PT-P6-E1.

## Acceptance criteria

- Each tool maps one-to-one to a Speaker Edit Service operation, resolves the current output-folder
  roots, and returns the recording ids the edit rewrote.
- An MCP rename / merge / split rewrites the same `final.md` files and emits the same events as the
  in-app editor path.
- A speaker-library mutation requested during capture returns a recording-in-progress error and
  leaves the library unchanged; reads are unaffected.

## Tasks

- PT-P6-E4-T1 — `RecordingGate` (reads `RecordingViewModel.status`) and the recording-in-progress
  tool-error shape.
- PT-P6-E4-T2 — `rename_speaker` / `merge_speakers` / `split_speaker`; assert parity with the
  PT-P6-E1 service effects through a `CallTool` round-trip.
- PT-P6-E4-T3 — the inverses `unmerge_speakers` / `unsplit_speaker`.
- PT-P6-E4-T4 — `delete_speaker` / `undelete_speaker` / `delist_speaker` / `undelist_speaker`.
- PT-P6-E4-T5 — the during-capture refusal across all nine tools.
