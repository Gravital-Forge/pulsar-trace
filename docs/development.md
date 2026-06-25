# Development environment

Contributor setup notes for PulsarTrace. Build, test, and sandbox rules for agentic work live in
`CLAUDE.md`; this file covers the host and the hardware-dependent tests.

## Host

Apple Silicon Mac, macOS 14+ (Sonoma or later). Transcription and diarization run on the Apple
Neural Engine via CoreML model bundles that download automatically on first use — there is no
native build step and no Python environment.

## Hardware-dependent tests

The capture tests exercise the real audio path and are opt-in:

- Install **BlackHole** (2ch is sufficient) and grant the terminal **Microphone** and **Screen
  Recording** permissions in System Settings → Privacy & Security.
- Run the opt-in device tests: `PULSARTRACE_DEVICE_TESTS=1 swift test --filter Capture`
  (they skip cleanly when BlackHole or the permissions are absent).
- Audio loopback smoke check: `scripts/audio-loopback-check.sh`.

## Build & test

See `CLAUDE.md` for the full build/test invocation and the Bash-sandbox rules (notably: `swift
build` / `swift test` run unsandboxed; use the narrow `--filter` suites, not `--filter
PipelineTests`).
