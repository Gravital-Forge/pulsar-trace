# PT-P4-E6 · Main-Window UX Overhaul — Completion Record

**Status:** Frozen · **Closed:** 2026-06-12

## What was built

The main window became a master–detail split (`RecordingsSplitView`, `PersistentHSplit`,
`RecordingsPaneModel`): a recordings list beside a transcript detail (`TranscriptDetailView`,
`TranscriptDetailModel`) that renders the selected transcript — including the one recording live — in
the window, with recordings grouped by day, renameable (`RecordingTitleStore`), and searchable
(find-in-transcript). Refinement status moved onto the recording rows and the separate refinements
pane was removed. The compact provisional `?` suffix is now emitted by the engine at the source
(`LiveRunner.resolveSystemLabel`), replacing the verbose `(provisional)`; live transcripts written
before this keep the old marker until refined — a versioned transcript-contract change with a stated
migration.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P4-R3** — `Sources/pulsartrace-mac/` — `MainWindowView.swift`, `RecordingsSplitView.swift`,
  `TranscriptDetailView.swift`, `PersistentHSplit.swift`;
  `Sources/PulsarTraceMenuBar/RecordingsPaneModel.swift`, `TranscriptDetailModel.swift`,
  `RecordingTitleStore.swift`; `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift`
  (`resolveSystemLabel` — source `?` marker)

## To flow into the product layer

- Update the Menubar Application with the master–detail window and in-window transcript viewing;
  update the Transcript Output contract with the compact source-emitted `?` provisional marker.
- Mint product requirement PT-R106 (in-window recordings and transcript viewing).
