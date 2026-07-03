# Development environment

Contributor setup notes for PulsarTrace. Build, test, and sandbox rules for agentic work live in
`CLAUDE.md`; this file covers the host and the hardware-dependent tests.

## Host

Apple Silicon Mac, macOS 14+ (Sonoma or later). Transcription and diarization run on the Apple
Neural Engine via CoreML model bundles that download automatically on first use — there is no native
build step and no Python environment.

## Hardware-dependent tests

The capture tests exercise the real audio path and are opt-in:

- Install **BlackHole** (2ch is sufficient) and grant the terminal **Microphone** and **Screen
  Recording** permissions in System Settings → Privacy & Security.
- Run the opt-in device tests: `PULSARTRACE_DEVICE_TESTS=1 swift test --filter Capture` (they skip
  cleanly when BlackHole or the permissions are absent).
- Audio loopback smoke check: `scripts/audio-loopback-check.sh`.

## Build & test

See `CLAUDE.md` for the full build/test invocation and the Bash-sandbox rules (notably:
`swift build` / `swift test` run unsandboxed; use the narrow `--filter` suites, not
`--filter PipelineTests`).

## UI end-to-end tests

XCUITest drives the real menubar app through the accessibility tree. The suite lives in `UITests/`;
the disposable Xcode project that hosts it is generated from `project.yml` (never committed).

Prerequisites: full Xcode (not just the CLT) and `brew install xcodegen`.

Run everything:

```
scripts/run-ui-tests.sh
```

One suite (arguments pass through to xcodebuild):

```
scripts/run-ui-tests.sh -only-testing:PulsarTraceUITests/FloorTests
```

Result bundles land in `.build/ui-test-results/` (they are large; prune old ones occasionally).

Each test launches the app with `PULSARTRACE_HOME` and `PULSARTRACE_DEFAULTS_SUITE` pointing at a
throwaway seeded home, so runs never touch your real settings, speaker library, recordings, or
events — the daily app can stay running (a second menu-bar icon appears during the run). Flow tests
that exercise recording set the fixture variables and add `PULSARTRACE_MODELS_DIR` to reuse your
existing model cache instead of re-downloading.

Element lookup is by accessibility identifier only; the convention and the full identifier list live
in `Sources/PulsarTraceMenuBar/A11yID.swift`.
