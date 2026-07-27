# PT-P6-E5 · Recording Tools & Discovery — Completion Record

**Status:** Frozen · **Closed:** 2026-06-29

## What was built

The recording-management and discovery tools landed, the full 17-tool surface was assembled, and the
live menubar app now hosts it over a single shared `SpeakerLibrary`.

- **`rename_recording`** (PT-P6-R6) — sets a recording's title by writing the `title.txt` sidecar via
  `RecordingTitleStore.write` (the same path the menubar uses); a blank title clears the sidecar back
  to the date-based default (the store's `normalized()` removes it). The folder name and stable
  `rec_…` id never change. Resolves the folder through the `RecordingsProviding` seam.
- **`request_refine` + `RefineRequesting`** (PT-P6-R6) — a `RefineRequesting` seam
  (`requestRefine(folderURL:recordingId:) async throws`) fronts the refinement queue; the tool
  resolves the recording, enqueues, and returns immediately with `{"status":"enqueued"}`. The live
  adapter forwards to `RefinementJobQueueViewModel.enqueueManual`, whose dedup makes a repeat enqueue a
  no-op.
- **`manual.md` + `ManualTool`** (PT-P6-R8, PT-P6-D5) — one versioned Markdown manual bundled as a
  target resource (`resources: [.copy("Resources/manual.md")]`), loaded via `Bundle.module` and
  returned by the `manual` tool. It describes PulsarTrace on its own terms (data model, every
  operation's semantics and reversibility) and a test gates that it names none of an external-system
  denylist (Claude, Codex, OpenAI, Anthropic, ChatGPT, Cursor, Cowork).
- **`MCPToolset.all(...)`** — the 17-tool assembly: 5 read + 9 speaker-write + 2 recording + the
  manual. A test asserts the exact 17 names and that `tools/list` carries a non-empty description and
  an object `inputSchema` for every one (PT-P6-R8 discoverability).
- **Live app wiring** — `MCPController` now builds the live adapters and the full toolset and
  constructs `MCPServer(port:auth:tools:)` with it. `LiveRecordings` reads `RecordingsScanner.refresh()`
  + `.recordings` and maps `RecordingViewModel.status`'s `.recording(id:startedAt:)` to the live id;
  `LiveRefine` hops to `@MainActor` to call `enqueueManual` with `MenuBarSettings.refineModelName`; the
  output roots are `[settings.outputFolderURL].compactMap{$0} + settings.previousFolderURLs` (identical
  to the editor's roots, so editor and agent scan the same folders).

### Single writer (PT-P6-D1)

`AppEnvironment` now owns one `SpeakerLibrary` (`public private(set) var speakerLibrary`, opened once in
`bootstrap()` with the shared `EventWriter`) and exposes `sharedSpeakerLibrary() async` that awaits the
bootstrap task before returning it. The menubar editor migrated from `SpeakerEditorViewModel.load(...)`
(which opened its own library) to a new `SpeakerEditorViewModel.using(library:events:settings:)` over
that shared instance; `SpeakerEditorView` resolves it from `@Environment(AppEnvironment.self)`. The
`MCPController` builds its `SpeakerEditService` over the same instance. So the editor and the agent
surface are exactly one writer — no two-cache drift.

## Deltas from the spec

- **`MCPController` resolves the library asynchronously.** It awaits `sharedSpeakerLibrary()` rather
  than reading a synchronous `environment.speakerLibrary`, fixing a real launch race where an
  MCP-enabled-at-launch toggle could run `apply` before bootstrap opened the library.
- **Editor construction.** `load(...)` is kept (documented as the standalone-open path); the shipped
  editor uses `using(...)`. The editor parity suite (`SpeakerEditorViewModel`, 15/15) confirms the
  migration is behaviour-preserving.
- **Test `Host` header.** The `discoverable` test uses `Host: 127.0.0.1:8080` (the SDK's
  `OriginValidator.localhost` requires a numeric port), matching the production route.
- **Content form.** `ManualTool` uses the non-deprecated `.text(text:annotations:_meta:)` form.

## Requirements satisfied

- **PT-P6-R6** (recording-management tools) — `Sources/PulsarTraceMCP/RecordingTools.swift`
  (`renameRecording`, `requestRefine`), `RefineRequesting.swift`.
- **PT-P6-R8** (self-describing discovery + operations manual) —
  `Sources/PulsarTraceMCP/Resources/manual.md`, `ManualTool.swift`, and the `discoverable` assertion in
  `Tests/MCPTests/MCPToolsetTests.swift`.
- **PT-P6-R3..R8 assembled + hosted** — `Sources/PulsarTraceMCP/MCPToolset.swift`; the live wiring in
  `Sources/pulsartrace-mac/MCPController.swift`.
- **PT-P6-D1 (single writer)** — `Sources/PulsarTraceMenuBar/AppEnvironment.swift` (the shared
  `SpeakerLibrary`), the editor's `using(...)` migration.

Code links carry `// PT-P6-R6`, `// PT-P6-R8`, `// PT-P6-R3` (on the toolset).

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Architecture:** extend the MCP Server component (PT-C22) with the recording tools, the bundled
  operations manual, and the `MCPToolset` assembly; record that the Menubar Application (PT-C16) now
  owns a single shared `SpeakerLibrary` (PT-P6-D1) used by both the editor and the in-process MCP
  server, and that `MCPController` hosts the live toolset. Note the recording tools reach the title
  sidecar (`RecordingTitleStore`) and the refine queue through seams.
- **Requirements:** mint the product requirements for PT-P6-R6 and PT-P6-R8 (both *Introduce*, from
  `PT-R115` upward).
- **Single-writer scope (for close-out + E6).** PT-P6-D1 is an *in-process* invariant for the mac app.
  The CLI (PT-P6-E6) is a separate process and cannot share this in-process library; routing the CLI
  through the shared edit service still produces correct file/event effects, but running CLI speaker
  edits while the app is live editing is a pre-existing separate-process caveat, not introduced here.
- **Traceability:** write-once rows for PT-P6-R6 and PT-P6-R8.
- **Reference sweep:** re-point every `// PT-P6-R6` / `R8` (and the `MCPToolset` `// PT-P6-R3`) code
  link to its minted product requirement id.
