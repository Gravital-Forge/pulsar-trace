# PT-P6-E6 · CLI Adoption — Completion Record

**Status:** Frozen · **Closed:** 2026-06-29

## What was built

The `pulsartrace speakers` mutating subcommands now route through the shared `SpeakerEditService`, so a
CLI edit drives the same retroactive `final.md` rewrite and paired events as the menubar and MCP
paths — closing the pre-existing PT-R90 gap where a CLI rename left past transcripts stale.

- **`OutputFolderRoots`** (engine) — `resolved(explicit:)` returns the explicit roots when non-empty,
  else the single default `~/Documents/PulsarTrace` (`defaultRoot`). This is the CLI-facing resolver a
  non-menubar caller needs (the menubar reads `MenuBarSettings`; the CLI cannot reach that target, so
  the engine is the correct shared layer).
- **`OutputFolderArgs`** (engine) — `parse(_:)` extracts repeated `--output-folder <path>` pairs and
  returns `(roots, positional)`; the CLI parses this before dispatching the subcommand.
- **`speakers rename` / `merge` / `delete` routed through `SpeakerEditService`** — `run` parses the
  flag, resolves the roots, opens the one `SpeakerLibrary`, builds a `SpeakerEditService`, and
  dispatches the mutating subcommands through it. `rename` and `merge` now report the rewritten
  transcript count (the old "past final.md files are not rewritten" note is gone); `delete` keeps its
  no-rewrite, soft-delete behaviour but flows through the shared service. `list` is unchanged.
- **Operations manual finalized** — a Discovery section was added so all 17 shipped tools are
  represented (the 16 named read/speaker/recording tools plus `manual` itself and the self-describing
  tool list); the external-system denylist gate (`ManualToolTests`) stays green.

## Deltas from the spec

- **Smoke posture.** The `pulsartrace` executable is not unit-tested (PT-P2-D9). The testable units —
  `OutputFolderRoots` and `OutputFolderArgs` — have unit tests; the CLI wiring is verified by
  `swift build` plus a dispatch/usage smoke against the built binary (e.g.
  `pulsartrace speakers --output-folder /tmp/x` prints "missing subcommand", proving the flag pair is
  stripped before dispatch). A full final.md-rewrite smoke would mutate the standard speakers DB and
  scan the real `~/Documents` (`AppPaths.standard` resolves the real home and cannot be redirected via
  env), so it was deliberately not run; the rewrite correctness rides on the PT-P6-E1
  `SpeakerEditService` suite, which is comprehensive.
- **In-file docs.** The `SpeakersCommand` type doc and `printUsage` were updated to reflect that rename
  and merge now rewrite past transcripts.
- **Manual.** The final pass added the Discovery section (no wording drift was found in the E3–E5 tool
  names/arguments; the manual already matched the shipped surface).

## Requirements satisfied

- **PT-P6-R9** (shared speaker-edit orchestration; CLI adoption) —
  `Sources/PulsarTraceEngine/Support/OutputFolderRoots.swift`,
  `Sources/PulsarTraceEngine/Support/OutputFolderArgs.swift`, and the routed `rename` / `merge` /
  `delete` in `Sources/pulsartrace/SpeakersCommand.swift` (each carrying `// PT-P6-R9`). Rewrite/event
  effects ride the E1 `SpeakerEditService`.
- **PT-P6-R8** (operations manual) — finalized `Sources/PulsarTraceMCP/Resources/manual.md`; gate
  `Tests/MCPTests/ManualToolTests.swift`.

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Architecture:** record that the Command-Line Interface (PT-C9) `speakers` mutating subcommands now
  route through the shared Speaker Edit Service (PT-P6-E1), gaining the retroactive `final.md` rewrite,
  and resolve output roots via the engine `OutputFolderRoots` (explicit `--output-folder` or the
  default `~/Documents/PulsarTrace`).
- **Documented limitation:** without `--output-folder`, only the default folder is scanned — strictly
  an improvement over the prior behaviour (which rewrote nothing), and worth a one-line note.
- **Requirements:** PT-P6-R9's product requirement (minted with E1's work) is `implemented_by` the
  menubar service, the MCP write tools, AND these CLI routes — its matrix row should list all three.
  PT-P6-R8's product requirement is `implemented_by` the manual + `ManualTool`.
- **Reference sweep:** re-point the `// PT-P6-R9` / `// PT-P6-R8` code links here to their minted
  product requirement ids.
- **Project status:** with E6 closed, every epic of P6 has working, tested (or build-and-smoke-
  verified) software. The project is ready for Erratum close-out — mint `PT-R115`+, the
  `PT-C22 · MCP Server` and Speaker Edit Service components, re-point all `// PT-P6-R*` code links, and
  write the matrix rows per `references/close-out.md`.
