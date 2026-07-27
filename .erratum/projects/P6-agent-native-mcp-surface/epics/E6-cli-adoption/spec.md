# PT-P6-E6 · CLI Adoption — Specification

**Status:** Frozen · **Opened:** 2026-06-26 · **Closed:** 2026-06-29

## Intent

Route the `pulsartrace speakers` subcommands through the Speaker Edit Service (PT-P6-E1) so a CLI
edit drives the retroactive `final.md` rewrite it previously skipped, completing the CLI clause of
PT-P6-R9 (PT-P6-D7), and resolve the output-folder roots a non-menubar caller needs. Reshapes the
Command-Line Interface (PT-C9); uses the Speaker Edit Service (PT-P6-E1). Depends on PT-P6-E1. With
this epic closed, project P6 is ready for Erratum close-out.

Scope: the CLI today exposes `speakers list / rename / merge / delete` (a hand-rolled dispatcher, not
`ArgumentParser`); this epic routes the three mutating ones through the shared service and adds a
repeatable `--output-folder` flag. It does **not** add new CLI subcommands for the full MCP op set —
PT-P6-R9's intent is that the CLI gains the rewrite, not new surface. The `pulsartrace` executable is
not unit-tested (like `pulsartrace-mac`), so the testable units are the engine-side
`OutputFolderRoots` / `OutputFolderArgs`; the rewrite correctness rides on the PT-P6-E1 service suite,
and the CLI wiring is verified by build + smoke.

## Acceptance criteria

- `pulsartrace speakers` rename / merge / delete (and the rest) call the Speaker Edit Service and
  produce the same `final.md` rewrite and events as the menubar and MCP paths.
- Output-folder roots resolve from an explicit `--output-folder` (repeatable) when given, otherwise
  the default `~/Documents/PulsarTrace`; without `--output-folder` only the default folder is
  scanned — a documented limitation, and strictly an improvement over the prior behaviour, which
  rewrote nothing.
- The operations manual Markdown is finalized and stays free of any external-system reference.

## Tasks

- PT-P6-E6-T1 — `OutputFolderRoots.resolved(explicit:)` in the engine (explicit roots versus the
  default).
- PT-P6-E6-T2 — `OutputFolderArgs.parse` (the `--output-folder` flag) and `speakers rename` routed
  through the service; the rewrite verified by build + smoke over a temp recording folder.
- PT-P6-E6-T3 — `speakers merge` / `delete` likewise route through the service.
- PT-P6-E6-T4 — finalize the `manual.md` wording (the gate that no external system is named).
