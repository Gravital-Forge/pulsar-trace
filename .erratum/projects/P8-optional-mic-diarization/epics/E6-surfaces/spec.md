# PT-P8-E6 · Surfaces: settings, recordings pane, CLI, MCP — Specification

**Status:** Frozen · **Opened:** 2026-07-29 · **Closed:** 2026-07-30

## Intent

Implements PT-P8-R8, PT-P8-R9, and PT-P8-R12 (PT-P8-R10's surface half rides along in the MCP
metadata task); touches PT-C16 (menubar app), PT-C9 (CLI), PT-C22 (MCP), PT-C17 (queue, unchanged
API — enqueue paths reused). The engine mechanics all exist after E1–E5; this epic exposes them:
the sticky default-off Settings toggle whose first enable triggers the owner-profile backfill
(E2-T4) and whose value stamps each new recording's `options.json` at record start; the
per-recording control beside Refine in the recordings pane (edit stamp → Refine = post-hoc
apply/revert); `pulsartrace record --diarize-mic` and `pulsartrace refine --diarize-mic on|off`
(persisting the sidecar before refining so subsequent refines agree); and the MCP surface —
`request_refine` gains an optional `diarize_mic` argument, recording metadata responses report the
stamp and `mic_diarized`.

## Acceptance criteria

- Settings pane: "Diarize microphone (in-person meetings)" toggle, persisted
  (`MenuBarSettings.diarizeMicEnabled`, default false), a11y id, survives relaunch (PT-P8-R12).
- First enable with no profile triggers backfill in the background exactly once; subsequent
  enables don't re-run it when a profile exists.
- Record start (app and CLI) writes `options.json` with the effective stamp; flipping the global
  toggle afterward changes nothing for existing recordings (PT-P8-R12 acceptance).
- Recordings pane detail: a "Diarize microphone" checkbox reflecting the stamp; toggling persists
  the sidecar; Refine re-runs through the queue; mic guests render pills like system speakers
  (PT-P8-R8).
- CLI: `record --diarize-mic` overrides the stamp at start; `refine --diarize-mic on|off` writes
  the sidecar then refines; both round-trip (PT-P8-R9).
- MCP: `request_refine` accepts optional `diarize_mic` (writes sidecar before enqueue); the
  recording-listing/metadata tool responses include the stamp and last-refine `mic_diarized`
  (PT-P8-R9, PT-P8-R10).

## Tasks

- PT-P8-E6-T1 — Settings toggle + first-enable backfill trigger
- PT-P8-E6-T2 — Record-time stamping (app + CLI record path)
- PT-P8-E6-T3 — Per-recording control in the recordings pane
- PT-P8-E6-T4 — CLI refine flag + MCP surface
