# PT-P7-E1 · Isolation & Fixture Capture — Completion Record

**Status:** Frozen · **Closed:** 2026-07-03

## What was built

Both testability seams landed exactly as specified, across eight commits (`21de752..3616e61`), each
task implemented TDD-first by a dispatched subagent and passed through a two-stage review (spec
compliance, then Swift quality) plus a final epic-level pass.

- **`EnvironmentOverrides`** (`Sources/PulsarTraceEngine/Support/EnvironmentOverrides.swift`) — the
  single reader for the five `PULSARTRACE_*` variables; `Sendable, Equatable`, empty-as-unset,
  injectable dictionary, `static let current` resolved once per process. URLs are built with
  explicit `isDirectory:` hints so equality never depends on a filesystem stat, and the doc states
  that values must be absolute paths.
- **Path choke points re-rooted** — `AppPaths.standard(overrides:)` (home + independent
  `modelsOverride`) and `OutputFolderRoots.defaultRoot(overrides:)`; the no-argument spellings
  delegate with `.current`, so every existing consumer — engine, capture daemon, MCP auth, CLI —
  picks the override up at call time with zero caller changes.
- **`MenuBarSettings`** — `init(defaults:overrides:)` resolves the store as explicit-param →
  `PULSARTRACE_DEFAULTS_SUITE` → production suite → `.standard`;
  `defaultOutputFolderURL(overrides:)` follows the home override. A fresh overridden suite yields
  the PT-P7-R9 safe defaults (`globalHotkey == nil`, `mcpServerEnabled == false`) — the production
  defaults already satisfied this; the isolation suite pins it.
- **`RecordPlan.Fixtures`** — failable pair (≥1 of system/mic), `from(_ overrides:)`, and a
  `fixtures:` parameter on `make` that empties `captureArguments` and emits
  `--live --out … --recording-id … --source fixture <primary>` (+ `--mic-fixture` when both set).
  The device branch moved into an `else` verbatim; parity pinned by the untouched pre-existing
  suite. A `primary` computed property keeps the force-unwrap next to the init invariant.
- **`EngineOnlyOrchestrator`** (`Sources/PulsarTraceMenuBar/EngineOnlyOrchestrator.swift`) — actor
  conforming to `RecordingOrchestrating`; spawns only the engine, stdio → `/dev/null` (the P5
  undrained-pipe lesson), exit observed via an `AsyncStream` latched before `run()` (no lost-exit
  race), `stop()` awaits the exit unconditionally, launch failure throws
  `RecordOrchestrator.StartError.engineLaunchFailed`. Inherits the parent environment — that
  inheritance is what carries the overrides into the engine, no orchestrator plumbing.
- **`RecordingViewModel` fixture mode** — `overrides: EnvironmentOverrides = .current` as the last
  init parameter; fixture starts skip the TCC preflight entirely (a fully-denied preflight stub
  cannot block one); `defaultOrchestratorFactory` returns `EngineOnlyOrchestrator` for a plan with
  empty `captureArguments` (the factory comment is the documented home of that convention); engine
  self-exit at fixture EOF finalizes via a shared `finalizeCleanStop(recordingId:)` — auto-refine
  enqueued, `.idle`, never `.crashed` — while device sessions still crash-flag exactly as before.
  The engine's live fixture branch logs one no-path line,
  `live session running from fixture capture` (Hard Invariant #7).

Four new test files (18 new tests): `EnvironmentOverridesTests`, `AppPathsOverrideTests`,
`RecordPlanFixtureTests` (incl. a device-knobs-ignored pin), `MenuBarSettingsIsolationTests`,
`EngineOnlyOrchestratorTests`, `RecordingFixtureModeTests`. Suites green at close: UnitTests
399/399, MenuBarTests 137/137, RecordOrchestrator 8/8.

## Deltas from the spec

None behavioural; all are review-driven tightenings folded into `ef30996` and `3616e61`:

- `EnvironmentOverrides` URLs take explicit `isDirectory:` hints (spec built them bare, which made
  `Equatable` stat-dependent); a trailing-slash normalization test pins it.
- `Fixtures.primary` replaces the spec's inline `fixtures.system ?? fixtures.mic!` in `make`.
- `EngineOnlyOrchestrator.stop()` awaits the exit task unconditionally instead of early-returning
  when the process already exited (a stop racing a natural exit now always returns post-exit).
- The `stopRecording()` tail and the fixture-EOF branch were congruent, so both call the extracted
  `finalizeCleanStop(recordingId:)`, which also resets `currentSessionIsFixture` (the spec snippet
  duplicated the statements and never reset the flag).
- The `defaultOrchestratorFactory` convention comment is an expanded wording of the spec's
  one-liner, explicitly naming itself the documented home of empty-argv ⇒ engine-only.
- Test hygiene: `defer`-based cleanup of temp defaults suites, stand-in scripts, and per-test
  output/home roots.

## Known residuals (for later epics)

- A deliberate `stopRecording()` mid-fixture SIGTERMs the engine with no EOF-drain grace (device
  path gets 60 s via `RecordOrchestrator`); the session still finalizes clean and auto-refines the
  partial folder. Only visible if a scenario stops mid-fixture — PT-P7-E3's record flow rides the
  EOF self-exit.
- `NSSplitView` divider autosave (`PersistentHSplit`) persists window geometry into
  `UserDefaults.standard`, outside the override suite — cosmetic PT-P7-R9 residue worth a note in
  the E2/E3 daily-state checks.
- The `<home>/Documents/PulsarTrace` rule exists in both `OutputFolderRoots.defaultRoot(overrides:)`
  and `MenuBarSettings.defaultOutputFolderURL(overrides:)`; both are test-pinned, one could delegate
  to the other on next touch.

## Requirements satisfied

- **PT-P7-R1** (environment-driven isolated app state) — `EnvironmentOverrides.swift`;
  `AppPaths.swift` (`standard(overrides:)`, `modelsOverride`); `OutputFolderRoots.swift`;
  `MenuBarSettings.swift` (store resolution, `defaultOutputFolderURL(overrides:)`);
  `RecordingViewModel.swift` (overrides threading). Subprocess inheritance verified: neither
  orchestrator touches `Process.environment`.
- **PT-P7-R2** (app-reachable fixture capture mode) — `RecordPlan.swift` (`Fixtures`, fixture argv);
  `EngineOnlyOrchestrator.swift`; `RecordingViewModel.swift` (preflight skip, factory branch,
  fixture-EOF clean stop); `Sources/pulsartrace-engine/main.swift` (no-path log line).
- **PT-P7-R9 substrate** — safe defaults pinned on a fresh overridden suite; full acceptance
  (mtime-verified untouched daily state) lands with the PT-P7-E2 floor suite.

Code links carry `// PT-P7-R1` and `// PT-P7-R2`.

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Mint** product requirements for PT-P7-R1 and PT-P7-R2 (both *Introduce*, from `PT-R126` upward
  per the PRD's numbering note).
- **Architecture:** the seams live inside existing components — the Menubar Application (PT-C16)
  gains the fixture session driver and overrides threading; the engine's Support layer gains the
  override reader. Fold into those component descriptions; the new E2E harness component (minted at
  close-out) references them.
- **Traceability:** write-once rows for the two minted requirements, `implemented_by` the symbols
  above.
- **Reference sweep:** re-point every `// PT-P7-R1` / `// PT-P7-R2` code link to the minted product
  requirement ids.
