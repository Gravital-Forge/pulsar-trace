# PT-P7-E1 · Isolation & Fixture Capture — Specification

**Status:** Open · **Opened:** 2026-07-02

## Intent

Implements PT-P7-R1 and PT-P7-R2 and lays the substrate for PT-P7-R9; touches the Menubar
Application (PT-C16), the Audio Source Layer (PT-C1, fixture path reuse), and bypasses the Capture
Daemon (PT-C15) in fixture mode. One new `EnvironmentOverrides` value in the engine target reads the
five `PULSARTRACE_*` variables once per process; `AppPaths`, `OutputFolderRoots`, and
`MenuBarSettings` consult it at their existing choke points so every mutable location re-roots
together; `RecordPlan` gains a fixture variant that emits the engine's existing `--source fixture` /
`--mic-fixture` arguments and no capture argv; and `RecordingViewModel` skips the TCC preflight,
launches a new engine-only orchestrator, and treats the engine's fixture-EOF self-exit as a clean
stop. With no variables set, every path, suite, and argv is byte-identical to today — the existing
suites are the parity guard.

## Acceptance criteria

- `EnvironmentOverrides` parses `PULSARTRACE_HOME`, `PULSARTRACE_DEFAULTS_SUITE`,
  `PULSARTRACE_MODELS_DIR`, `PULSARTRACE_SYSTEM_FIXTURE`, `PULSARTRACE_MIC_FIXTURE`; empty values
  count as unset; `.current` reads the process environment exactly once.
- With `PULSARTRACE_HOME` set, `AppPaths.standard` (app support, events, speakers DB, MCP token,
  logs, model cache), `OutputFolderRoots.defaultRoot`, and `MenuBarSettings.defaultOutputFolderURL`
  all resolve under the override; `PULSARTRACE_MODELS_DIR` re-points only the model store;
  `PULSARTRACE_DEFAULTS_SUITE` substitutes the settings suite. Engine subprocesses inherit the same
  behavior through the process environment — no orchestrator plumbing.
- With at least one fixture variable set, a `RecordPlan` carries empty `captureArguments` and engine
  argv `--live --out … --recording-id … --source fixture <primary>` (plus `--mic-fixture <mic>` when
  both are set); `RecordingViewModel.startRecording()` runs no permission preflight, spawns only the
  engine (via `EngineOnlyOrchestrator`), and the engine's self-exit at fixture end finalizes the
  session exactly like a user stop (auto-refine enqueued, status `.idle`, never `.crashed`). The
  engine logs one no-path line noting fixture capture.
- Sockets stay under `$TMPDIR/PulsarTrace/` (per-recording-id, ephemeral — no isolation needed).
- All existing suites pass unchanged; every new behavior has a test that pins it.

## Tasks

- PT-P7-E1-T1 — `EnvironmentOverrides`: the five variables, empty-as-unset, injectable environment.
- PT-P7-E1-T2 — Re-root `AppPaths` and `OutputFolderRoots` through the overrides.
- PT-P7-E1-T3 — `MenuBarSettings`: overridable defaults suite and default output folder.
- PT-P7-E1-T4 — `RecordPlan.Fixtures` and the fixture argv variant.
- PT-P7-E1-T5 — `EngineOnlyOrchestrator`: engine-only session driver conforming to
  `RecordingOrchestrating`.
- PT-P7-E1-T6 — `RecordingViewModel` fixture mode: preflight skip, factory branch, clean fixture-EOF
  finish, engine log line.
