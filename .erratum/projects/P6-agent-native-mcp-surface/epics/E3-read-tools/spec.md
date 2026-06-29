# PT-P6-E3 · Read Tools — Specification

**Status:** Open · **Opened:** 2026-06-26

## Intent

Add the read surface to the MCP server: tools that list recordings and the speaker library, fetch a
single recording's metadata or a single speaker with its appearances, and return recent events —
each returning identity, state, and filesystem paths, and never transcript or audio bytes.
Implements PT-P6-R3, PT-P6-R4, PT-P6-R7. Extends the MCP Server (PT-C22) with the tool registry;
reads the Speaker Library (PT-C5) directly, the recordings scan and live-recording status through a
`RecordingsProviding` seam (the live adapter over `RecordingsScanner` + `RecordingViewModel.status`
is wired in the app composition root), and the Events Log (PT-C6). Depends on PT-P6-E2.

Two pieces are net-new engine/menubar work this epic surfaces, not just wiring: `list_recordings`
needs a `language` field that `RecordingEntry` does not carry today (added, decoded from
`metadata.json`), and `recent_events` needs a new `EventLogReader` because the existing
`EventLogTail` reads only the current day and has no `since`/timestamp filter. `PulsarTraceMCP` gains
a dependency on `PulsarTraceMenuBar` (for `RecordingEntry`); that target has no SwiftUI, so the MCP
core stays non-SwiftUI.

## Acceptance criteria

- `list_recordings` returns, per recording: id, title, start time, duration, language, refinement
  state, a live-in-progress flag, the speakers present, and the filesystem paths to the final and
  live transcripts; `since` / `until` / `status` / `limit` filter the result.
- `get_recording_meta` returns one recording's metadata and paths by id, with a clear not-found
  error.
- `list_speakers` returns the live speakers (id, name, appearance count, last-seen); `get_speaker`
  adds the recordings the speaker appears in.
- `recent_events` returns recent events with optional `since` and type filters.
- No read tool returns transcript or audio content — only metadata and paths.

## Tasks

- PT-P6-E3-T1 — `ToolRegistry` + `MCPTool` plus the SDK `ListTools` / `CallTool` wiring and the
  `tools:` injection point on `MCPServer` (a registered tool round-trips through `CallTool`).
- PT-P6-E3-T2 — `list_recordings`: the `RecordingsProviding` seam, the `RecordingEntry.language`
  addition, the DTO, the `since`/`until`/`status`/`limit` filters, the `is_live` flag, and the paths.
- PT-P6-E3-T3 — `get_recording_meta`: by id, with the not-found error shape.
- PT-P6-E3-T4 — `list_speakers` / `get_speaker` (with appearances) over the `SpeakerLibrary`.
- PT-P6-E3-T5 — `recent_events`: a new `EventLogReader` (since/type filters, multi-day) plus the tool.
