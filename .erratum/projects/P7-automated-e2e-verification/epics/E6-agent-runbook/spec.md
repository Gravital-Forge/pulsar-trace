# PT-P7-E6 · Agent Verification Runbook — Specification

**Status:** Frozen · **Opened:** 2026-07-02 · **Closed:** 2026-07-28

## Intent

Implements PT-P7-R8 per PT-P7-D7; drives the Menubar Application (PT-C16) through the accessibility
layer and reads ground truth through the transcript artifacts, the events log, and the MCP Server
(PT-C22). Pure documentation — the deliverable is `docs/agent-verification.md`, a runbook an AI
agent (Claude Code with an AX-capable tool; Peekaboo as the reference) follows to walk the manual
smoke checklist's UI items against a fixture-driven isolated instance and produce a per-item
pass/fail report. No app changes; the E1 seams and the E3 checklist markers are its substrate.

## Acceptance criteria

- The runbook covers: purpose and non-goals (advisory, never a merge gate); prerequisites (Peekaboo
  or equivalent, built dev app via `scripts/make-dev-app.sh`, TCC notes); isolation setup (fresh
  `PULSARTRACE_HOME` + suite + fixture variables + shared models dir; **daily instance quit** and
  why); state preparation (a fixture recording made through the UI supplies material for the speaker
  items); the walk itself (a table: checklist item → UI action via AX → ground-truth check via
  file/event/MCP tool); the report template; and teardown.
- Every ground-truth check names its concrete channel (`live.md` / `final.md` path shape, an event
  type, or an MCP tool name from the PT-C22 surface).
- `docs/release-smoke-test.md` and `docs/development.md` cross-link the runbook (one line each).

## Tasks

- PT-P7-E6-T1 — Write `docs/agent-verification.md`.
- PT-P7-E6-T2 — Cross-links from the smoke checklist and the development doc.
