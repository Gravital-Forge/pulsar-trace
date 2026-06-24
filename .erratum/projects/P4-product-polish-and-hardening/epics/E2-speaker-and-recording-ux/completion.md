# PT-P4-E2 · Speaker & Recording UX — Completion Record

**Status:** Frozen · **Closed:** 2026-06-09

## What was built

Recording rows gained speaker pills, and merge no longer leaves duplicate speaker rows in the
metadata sidecar. The live transcript got smart auto-scroll (`AutoScrollController`): it follows the
newest line when scrolled to the bottom and shows a "jump to newest" pill otherwise. "Don't
recognize this speaker" delists a speaker — removing them from people and retroactively rewriting
the affected final transcripts — and the per-line fallback for speech overlapping no diarized turn
now labels the line so no text is lost but earns no speaker pill or metadata entry, so it never
reads as a phantom person.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P4-R2** — `Sources/PulsarTraceMenuBar/` — `SpeakerEditorViewModel.swift`,
  `AutoScrollController.swift`; `Sources/pulsartrace-mac/SpeakerPillsView.swift`;
  `Sources/PulsarTraceEngine/Refinement/FinalMarkdownRewriter.swift`, `TranscriptAssembly.swift`

## To flow into the product layer

- Update the Menubar and Speaker Library descriptions with delisting and the non-person fallback.
- Mint product requirement PT-R105 (speaker delisting and cleaner surfacing).
