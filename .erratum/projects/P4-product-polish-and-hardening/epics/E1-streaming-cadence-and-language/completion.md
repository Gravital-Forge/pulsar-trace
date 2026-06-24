# PT-P4-E1 · Streaming Cadence & Language — Completion Record

**Status:** Frozen · **Closed:** 2026-05-31

## What was built

The live decode step and window were lengthened (step to a few seconds, window to ten) to roughly
halve live decode load while keeping lag within bound. Per-window language detection was restricted to
a user-configured allow-list — enforced in `WhisperTranscriber` via `WhisperOptions.allowedLanguages`
over the `WhisperLanguageCatalog`, and surfaced through a multi-select / searchable settings picker —
so the live pass no longer drifts between languages mid-meeting.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P4-R1** — `Sources/PulsarTraceEngine/Transcription/WhisperTranscriber.swift`,
  `WhisperOptions.swift` (`allowedLanguages`), `WhisperLanguageCatalog.swift`;
  `Sources/PulsarTraceEngine/Streaming/StreamingTranscriber.swift` (decode cadence);
  `Sources/PulsarTraceMenuBar/MenuBarSettings.swift`, `Sources/pulsartrace-mac/SettingsView.swift`

## To flow into the product layer

- Update Streaming Transcription with the tuned cadence and the language allow-list.
- Mint product requirement PT-R102 (live language allow-list).
