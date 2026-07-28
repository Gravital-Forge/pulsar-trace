# PT-P7-E6 · Agent Verification Runbook — Completion Record

**Status:** Frozen · **Closed:** 2026-07-28

## What was built

`docs/agent-verification.md` (PT-P7-R8, per PT-P7-D7) — the runbook an AI agent follows to walk
the manual smoke checklist's UI items against a fixture-driven isolated instance. Pure
documentation; two commits (`d711571`, `b51f4aa`). All sections the spec requires are present:
purpose and non-goals (advisory, never a gate; *(automated)* items skipped), prerequisites
(Peekaboo as the AX reference driver, `scripts/make-dev-app.sh`, Accessibility TCC — and why
screenshot-coordinate driving is excluded), isolation setup (fresh `PULSARTRACE_HOME` + defaults
suite + fixture variables + shared models dir, daily instance quit and why), state preparation
(one UI-started fixture recording supplies the material), the walk (13 items, each naming its
concrete ground-truth channel — a `live.md`/`final.md`/`.bak` path shape, an events-log type such
as `speaker_renamed`/`final_md_rewritten`, or a PT-C22 MCP tool name), the report template, and
teardown. Cross-links added: `docs/release-smoke-test.md` intro and the end of
`docs/development.md`'s UI-test section (one line each).

Every checklist-item claim was verified against the code at writing time: the five named MCP read
tools plus `manual` exist in `PulsarTraceMCP`; recording rename exists in the UI
(`RecordingsSplitView` inline edit) and `get_recording_meta` reads it; the paired fixtures are
~16 s (512 KB at 16 kHz mono s16); the marker strings and the events/output path shapes under a
re-rooted home match `AppPaths`/`OutputFolderRoots`.

## Deltas from the spec

- **The walk is a numbered list, not a table.** The task skeleton's three-column table exceeds the
  repo's MD013 line limit once mdformat pads cells (217 chars); per the documented convention,
  over-wide tables become structured lists. Content is unchanged: item → AX action → *Ground
  truth:* channel.
- **The skeleton's `open --env NAME` launch was corrected to full `NAME=value` pairs.** `open
  --env` with a bare name sets the variable to an *empty string*, which `EnvironmentOverrides`
  deliberately treats as unset — the skeleton's command would have launched the instance with no
  isolation, silently touching daily state. The runbook now passes explicit pairs and explains the
  trap; the direct-binary fallback launch is kept.
- The walk grew from the skeleton's 8 rows to 13 (unrecognize, delete + undo toast, split,
  crash-state recovery, moved-folder refresh — all unmarked checklist items AX can reach), and the
  not-walkable list is enumerated explicitly (hardware/OS flows, global hotkey, notifications,
  play-sample audio, visual judgements). Split's row notes unsplit has no GUI affordance (the E3
  residual stands).
- A caution was added that ground-truth reads use MCP **read** tools only — performing edits via
  MCP write tools would test the wrong surface.

## Known residuals

- The runbook has not yet been executed end-to-end by an agent (this session ran with the user's
  desk unavailable — no UI driving). Its factual claims are code-verified, but the first real walk
  is the validation of its *ergonomics*, and per the PRD acceptance for PT-P7-R8 that walk (report
  produced, daily state untouched) should happen before or at project close-out.
- E3's split-flow residuals stand: split has no undo toast and unsplit is GUI-unreachable; the
  runbook marks unsplit not-walkable accordingly.

## Requirements satisfied

- **PT-P7-R8** — `docs/agent-verification.md` plus the two cross-links; the walk's ground-truth
  checks name their concrete channels throughout.

Documentation-only: no code links to carry.

## To flow into the product layer

At project close-out: PT-P7-R8's mint gets `implemented_by: docs/agent-verification.md` (+ the two
cross-link lines). The first executed walk's report is the acceptance evidence to attach or note.
