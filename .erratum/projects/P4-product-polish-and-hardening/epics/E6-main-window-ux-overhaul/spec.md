# PT-P4-E6 · Main-Window UX Overhaul — Specification

**Status:** Frozen · **Opened:** 2026-06-10 · **Closed:** 2026-06-12

## Intent

Rework the main window into a master–detail experience: recordings list beside an in-window transcript
detail that renders the selected (including live) transcript, renameable recordings, find-in-transcript,
and the refinements pane folded into the recording rows (PT-P4-R3). Also moves the compact provisional
`?` marker to the engine source. Touches the Menubar Application (PT-C16), Recording Durability /
live writer (PT-C14), and the Transcript Output contract (PT-C11).

## Acceptance criteria

- Recordings render master–detail; the selected transcript — including one recording live — shows
  in-window and is searchable; recordings can be renamed.
- Refinement status lives on the recording rows, not a separate pane.
- The live transcript marks provisional speakers with a compact `?` suffix emitted at the source;
  prior live transcripts keep the old marker until refined.

## Tasks

- PT-P4-E6-T1 — Master–detail recordings split with in-window transcript detail
- PT-P4-E6-T2 — Renameable recordings; find-in-transcript; fold the refinements pane into rows
- PT-P4-E6-T3 — Emit the compact provisional `?` marker at the engine source
