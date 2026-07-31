# PT-P8-E6 · Surfaces: settings, recordings pane, CLI, MCP — Completion Record

**Status:** Frozen · **Closed:** 2026-07-30

## What was built

Commit ad96534, exposing the E1–E5 machinery:

- **Settings toggle (PT-P8-R12):** `MenuBarSettings.diarizeMicEnabled` — persisted, default off, the
  `systemAudioEnabled` pattern — rendered as "Diarize microphone (in-person meetings)" with
  `pt.settings.diarizeMicToggle`. The **always-mounted MenuBarExtra scene** (not the Settings view)
  observes the first false→true transition and calls `AppEnvironment.diarizeMicToggled`: if no owner
  profile exists, `OwnerProfileBackfill` runs once at utility priority over the current +
  previously-used output roots (de-duplicated), logging its summary. A present profile ⇒ no
  backfill; re-enables are harmless no-ops.
- **Record-time stamping (PT-P8-R2/R12):** both record paths write `options.json` immediately after
  folder creation and before the engine spawns, and pass the same value into
  `RecordPlan.make(diarizeMic:)` so flag and sidecar always agree. The app path stamps from the
  sticky toggle best-effort (a write failure reads as off, never blocks recording); the CLI's
  explicit `record --diarize-mic` hard-fails on a write error. `RecordOrchestrator` never learns
  about the sidecar — it takes pre-built argv, so each caller stamps (the task's anticipated
  fallback; there is no single convergence point).
- **Per-recording control (PT-P8-R8):** `RecordingEntry.diarizeMicStamp` (decoded in both entry
  paths); a "Diarize microphone" checkbox in the recordings detail header
  (`pt.recordings.detail.diarizeMicCheckbox`, disabled while live) that persists via
  `RecordingsPaneModel.setDiarizeMic` — the rename flow's write-then-refresh shape — leaving the
  Refine affordance untouched: the post-hoc flow is checkbox → Refine.
- **CLI refine (PT-P8-R9):** `refine --diarize-mic on|off` (space and `=` forms; anything else is a
  parse error) — a tri-state override persisted to the *resolved* recording folder (the exact
  directory the pipeline reads) before refining, so subsequent refines agree; omitted flag leaves
  the stamp untouched.
- **MCP (PT-P8-R9/R10):** `request_refine` gained optional `diarize_mic` (sidecar write before
  enqueue; tick-then-refine documented in the tool description); recording listings report
  `diarize_mic_stamp` (the input: what the next refine honors) and `mic_diarized` (the output: what
  the current `final.md` reflects, read tolerantly from `metadata.json`); the MCP manual gained the
  mode paragraph.

## Deltas from the task skeleton

- **CLI parsers were not testable:** they live in the `pulsartrace` executable, which no test target
  depended on. `Package.swift` now lists `pulsartrace` as a `UnitTests` dependency
  (`@testable import` of an `@main` executable — standard SwiftPM), and the parse tests live in
  `Tests/UnitTests/`.
- The draft's `paneModel.refreshEntry(folderURL:)` does not exist; per "do not invent a new refresh
  path" the checkbox reuses the rename action's exact write-then-`scanner.refresh()` shape as
  `setDiarizeMic`.
- `mic_diarized` is read directly from `metadata.json` in the MCP DTO rather than widening
  `RecordingEntry` with an MCP-only field.
- The backfill trigger lives on the composition-root scene (the `globalHotkey` precedent) so a
  launch that never opens Settings still backfills.
- The `isMicrophone` uniqueness sweep found no app site assuming a single mic row (E5's sites
  filter/contains correctly; `SpeakerPillsView` dedupes on label+flag) — no changes.

## Empirical findings worth keeping

- The first-enable backfill's diarizer competes with a running refine job for the ANE — the queue's
  `PauseGate` does not govern ad-hoc work. Accepted per the task; **close-out follow-up candidate:**
  promote backfill to a queue job if contention bites.
- Appending a defaulted parameter to a public init (here `RecordingEntry`) breaks incremental links
  against stale test objects (third occurrence this project — E3, E5, E6). Clean builds are
  unaffected; a `swift package clean` is prudent for the first CI run on this branch if `.build` is
  cached.

## Requirements satisfied

- **PT-P8-R12** — sticky toggle persists, stamps new recordings, never touches existing ones
  (stamp-independence pinned by test); first enable triggers backfill exactly once.
- **PT-P8-R8** — settings toggle + per-recording checkbox + unchanged Refine = post-hoc
  apply/revert; mic guests render with the standard pills.
- **PT-P8-R9** — CLI record/refine overrides round-trip the sidecar; MCP accepts the option and
  reports the state.
- **PT-P8-R10** (surface half) — the MCP metadata responses carry the stamp and `mic_diarized`.

## To flow into the product layer

At close-out: PT-P8-R8/R9/R12 mints anchor to the settings key, the two stamping call sites, the CLI
flags, and the MCP tool fields; the ANE-contention follow-up and the stale-incremental-link
observation go to the project decision log / known-issues consideration.
