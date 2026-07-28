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

## App-level real-audio smoke

```
scripts/e2e-audio-smoke.sh
```

Plays a committed voice sample through BlackHole into the real capture daemon and asserts the
refined transcript against the sample's reference — the one end-to-end path fixture-mode UI tests
cannot prove. Needs the same setup as the device tests (BlackHole 2ch, Microphone permission for
the terminal) plus `brew install switchaudio-osx`. State is isolated to a temp home; the default
output device is restored on exit.

`audio-loopback-check.sh` remains the narrower environment diagnostic (does audio route through
this host's loopback at all); the smoke is the product test on top of it.

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

### Automation-mode authorization (dev session)

macOS gates every XCUITest run behind "Automation Mode". `testmanagerd` enables it per test
session, and the enable sometimes pops a SecurityAgent password dialog ("XCTest is trying to Enable
UI Automation"). The grant persists for the login session but is invalidated by a screen lock (and
by logout) — after which the next unattended run stalls for ~60 s and fails with
`Failed to initialize for UI testing: … Timed out while enabling automation mode.`

To keep suites running unattended, front that prompt at a moment of your choosing rather than letting
it ambush a run:

```
scripts/start-ui-session.sh
```

Run it once at the start of a dev session, and again after every screen lock. It runs the 15-second
launch smoke; if the password dialog appears, enter your login password. It then prints one verdict:
`✅ Automation session ACTIVE` (suites can now run unattended) or `❌ Authorization NOT granted`
(re-run and answer the dialog).

If a normal `scripts/run-ui-tests.sh` run hits the timeout signature above, it prints a boxed hint
telling you to run `scripts/start-ui-session.sh`, enter the password, then retry. Both scripts write
a per-run log under `.build/ui-test-results/`.

This is a local-desktop concern only: hosted CI runners pre-authorize automation mode, so the
ceremony is never needed there.
