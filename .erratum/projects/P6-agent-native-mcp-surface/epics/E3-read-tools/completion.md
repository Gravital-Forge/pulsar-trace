# PT-P6-E3 · Read Tools — Completion Record

**Status:** Frozen · **Closed:** 2026-06-29

## What was built

The MCP server gained its tool registry and a five-tool read surface that returns identity, state, and
filesystem paths and never transcript or audio bytes (PT-P6-D8).

- **Registry (`ToolRegistry` + `MCPTool`).** `MCPTool` bundles a name, description, `Value` input
  schema, and an async `@Sendable` handler returning a `CallTool.Result`. The `ToolRegistry` actor
  holds the tools insertion-ordered, exposes `allTools() -> [Tool]` and `call(name:arguments:)` (an
  `isError` result for an unknown tool), and `install(on:)` registers the SDK `ListTools` / `CallTool`
  handlers, each reading the live tool set at call time. `MCPServer` gained a `tools:` init parameter
  that registers and installs the registry on `start()`, replacing E2's empty `tools/list` stub.
- **`list_recordings`** (PT-P6-R3) — returns, per recording, `id`, `title`, `start`,
  `duration_seconds`, `language`, `refinement_state`, `is_live`, `speakers[]`, and the `final_path` /
  `live_path` / `audio_system_path` / `audio_mic_path`; `since` / `until` (ISO-8601 on start) / `status`
  (live | refined | all) / `limit` filter the result. A `RecordingsProviding` seam supplies the
  snapshot and the live-recording id (fake in tests; the live adapter is wired in E5).
- **`get_recording_meta`** (PT-P6-R3, PT-P6-D8) — one recording by id, the same DTO as a list item
  under a `recording` key, with a clear not-found / missing-`id` error. Named `…_meta`, never returns
  content.
- **`list_speakers` / `get_speaker`** (PT-P6-R4) — the live (non-deleted, non-delisted) speakers with
  `id` / `name` / `appearance_count` / `last_seen`; `get_speaker` adds the `appearances`
  (`recording_id` / `recording_folder` / `observed_at`), erroring on a miss. Both read the engine
  `SpeakerLibrary` actor directly.
- **`recent_events` + `EventLogReader`** (PT-P6-R7) — a new engine `EventLogReader` returns recent
  events newest-first across the daily `YYYY-MM-DD.jsonl` files, filtered by an inclusive ISO-8601
  `since` (lexicographic string compare on the second-precision UTC `ts`) and a type set, capped at a
  limit; the `recent_events` tool wraps it, accepting `since`, `type` (string or array), and `limit`.

Net-new non-MCP work this epic surfaced: `RecordingEntry.language` (decoded from `metadata.language`,
`nil` when unrefined) — `list_recordings` must report it; and the `EventLogReader` engine type, because
the existing `EventLogTail` reads only the current day and has no `since`/type filter. `PulsarTraceMCP`
gained a dependency on `PulsarTraceMenuBar` (for `RecordingEntry`); that target has no SwiftUI, so the
MCP core stays non-SwiftUI, and `PulsarTraceMenuBar` does not (and must not) import `PulsarTraceMCP`.

## Deltas from the spec

All adaptations preserve behaviour; the tools and tests are otherwise as planned.

- **SDK content form.** The SDK's `Tool.Content.text` is 3-arity
  (`text(text:annotations:_meta:)`); the single-arg `.text("…")` is deprecated. `ReadTools`'
  `jsonResult` / `errorResult` use the non-deprecated form. (One `ToolRegistryTests` echo tool keeps the
  deprecated single-arg form verbatim — a warning, not a failure.)
- **Swift-6 Sendable.** The shared `ISO8601DateFormatter` is `nonisolated(unsafe) static let iso`,
  matching the existing `RecordingEntry.iso8601` convention (configured once, read-only thereafter).
- **`RecordingEntry` surface.** The DTO uses the real computed paths `finalURL` (`final.md`) /
  `liveURL` (`live.md`), `displayTitle`, and the engine constants
  `RecordingFolder.FileName.audioSystem` (`audio-system.wav`) / `.audioMic` (`audio-mic.wav`).
  `RefinementMetadata.language` is non-optional on the metadata; `RecordingEntry.language` is its
  optional projection (nil only when unrefined).
- **Speaker surface.** `Speaker.lastSeen` and `SpeakerAppearance.observedAt` are already ISO-8601
  strings, surfaced verbatim (no Date conversion).
- **Registration deferred.** The read tools are factories; they are assembled into the live server's
  toolset and wired through the app composition root in PT-P6-E5 (`MCPToolset.all` + `MCPController`),
  not here. The menubar regression guard (`SpeakerEditorViewModel`, 15/15) confirmed the
  `RecordingEntry.language` addition is safe.

## Requirements satisfied

- **PT-P6-R3** (recording query tools — metadata/paths, never content; filters) —
  `Sources/PulsarTraceMCP/ReadTools.swift` (`listRecordings`, `getRecordingMeta`, `recordingDTO`),
  `RecordingsProviding.swift`; `Sources/PulsarTraceMenuBar/RecordingEntry.swift` (`language`);
  `Sources/PulsarTraceMCP/ToolRegistry.swift` (the registry the tools plug into).
- **PT-P6-R4** (speaker query tools) — `ReadTools.swift` (`listSpeakers`, `getSpeaker`,
  `speakerSummary`) over the `SpeakerLibrary` actor.
- **PT-P6-R7** (event query tool) — `Sources/PulsarTraceEngine/Events/EventLogReader.swift` and
  `ReadTools.recentEvents`.

Code links carry `// PT-P6-R3`, `// PT-P6-R4`, `// PT-P6-R7`.

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Architecture:** extend the MCP Server component (PT-C22) with the tool registry and the read tool
  surface; record that the Events Log (PT-C6) gained the `EventLogReader` reader (a sibling of the
  append-only `EventWriter`), and that the Menubar Application (PT-C16) `RecordingEntry` gained a
  `language` field. The recordings snapshot is reached through the `RecordingsProviding` seam, whose
  live adapter lands in E5.
- **Requirements:** mint the product requirements for PT-P6-R3, PT-P6-R4, PT-P6-R7 (all *Introduce*,
  from `PT-R115` upward), `implemented_by` the symbols above.
- **Traceability:** write-once rows for the three product requirements.
- **Reference sweep:** re-point every `// PT-P6-R3` / `R4` / `R7` code link to its minted product
  requirement id.
