# PT-P2-E4 · Menubar UI — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

The `PulsarTraceMenuBar` library holds the `@Observable` state: a status machine (`MenuBarState`),
`RecordingViewModel` (start/stop with crash-watch), `MenuBarSettings` persisted to user defaults,
`SpeakerEditorViewModel` (list/rename/merge/split/delete with undo and name validation),
`RecordingsScanner` (recordings from metadata sidecars, with re-refine), and `LiveTranscriptWatcher`
(read-only poll-tail of the live transcript). `FinalMarkdownRewriter` retroactively rewrites the
affected final transcripts after a speaker rename/merge/split/unmerge — resolving affected recordings
through the appearances table, writing atomically with backups, updating metadata labels, and never
touching the live transcript — paying the PT-P1-D16 deferral; the library's mutation methods emit the
paired rewrite event with the populated recording set. `OfflineRefiner` provides the shared in-process
refine the menubar uses instead of shelling out. The `pulsartrace-mac` executable is a menubar shell
with an accessory activation policy and a passive global hotkey. Live and refine models are separate
settings; the output folder is stored as a plain path.

## Deltas from the spec

The onboarding tour is stubbed (deferred), so it is not introduced as a product requirement.

## Requirements satisfied

- **PT-P2-R10** — `Sources/PulsarTraceMenuBar/` — `MenuBarState.swift`, `RecordingViewModel.swift`,
  `MenuBarSettings.swift`, `AppEnvironment.swift`; `Sources/pulsartrace-mac/`
- **PT-P2-R11** — `Sources/PulsarTraceMenuBar/` — `SpeakerEditorViewModel.swift`, `RecordingsScanner.swift`, `LiveTranscriptWatcher.swift`
- **PT-P2-R12** — `Sources/PulsarTraceEngine/Refinement/FinalMarkdownRewriter.swift`; `SpeakerLibrary` mutation methods + paired events

## To flow into the product layer

- Mint components: Menubar Application; mint the in-process Offline Refiner as part of the Refinement
  Pipeline's surface; extend the Events Log contract with the live-transcript and final-rewrite events.
- Mint product requirements PT-R40, PT-R41, PT-R42 (status/control/settings); PT-R31, PT-R43, PT-R44,
  PT-R45 (editor/list/preview); PT-R90 (retroactive rewrite + paired event).
