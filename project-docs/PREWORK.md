# PREWORK — dev environment, audio stack & sandbox model

Point a new session at this file. It records what was verified about the
development host and — more importantly — **how to run things**: which commands
work inside the Claude Code Bash sandbox, which must run outside it, and why.

Work done: 2026-05-16, on the first real-audio-capable host.

## Host

Apple M2 MacBook Air, macOS 26 (Darwin 25.x), in a cmux terminal. BlackHole 2ch
+ 16ch installed. Microphone **and** Screen Recording TCC permissions are
granted to the terminal. whisper.cpp is built with Metal; the Python venv
(pyannote 4.0.4 / torch 2.12.0) is built by `python/build-venv.sh`.

`python/build-venv.sh` defaults to `/opt/homebrew/bin/python3.12`, which does
not exist here — build the venv with
`PULSARTRACE_PYTHON=~/.pyenv/versions/3.12.9/bin/python3.12 python/build-venv.sh`.

## Verified working — the whole audio stack

- AVFoundation audio-device enumeration (10 inputs, incl. BlackHole 2ch/16ch).
- BlackHole loopback: play a sample into BlackHole, capture it back, transcribe
  it verbatim — `scripts/audio-loopback-check.sh` runs the whole check.
- ScreenCaptureKit system-audio capture: `SCStream` with `capturesAudio`
  delivers real, non-silent audio buffers.
- Full offline pipeline: whisper (Metal) + pyannote diarization → `final.md`.
- Opt-in device tests exist for both — see "Running things" below.

## The sandbox model — what runs where, and why

The Claude Code Bash sandbox (`.claude/settings.json` → `sandbox`) does
filesystem + network isolation only. Some of PulsarTrace's work runs fine inside
it; some hits walls.

**Runs sandboxed** (auto-approved via `autoAllowBashIfSandboxed`):
- AVFoundation audio-device capture (ffmpeg avfoundation, BlackHole). Works
  because `sandbox.network.allowMachLookup` allowlists the CoreAudio / capture
  Mach services. Device *enumeration* needs `com.apple.audio.*` / `cmio`;
  device *capture* additionally needs `coremedia` + `tccd` (the TCC mic check).
- whisper's **CPU** backend + pyannote diarization (so a CPU-mode `refine`
  could run sandboxed if its output path were inside the sandbox).

**Must run outside the sandbox** (allowlisted in `.claude/settings.json` →
`permissions.allow`, so they don't prompt):
- `swift build` / `swift test` — SwiftPM compiles the package manifest in its
  own nested `sandbox-exec`; the outer sandbox blocks nested sandboxing.
- whisper's **Metal GPU** path (`pulsartrace refine`, `pulsartrace-engine`) —
  Metal needs IOKit GPU access, which the sandbox exposes no knob for; the
  Metal backend SIGSEGVs on buffer allocation inside the sandbox.
- ScreenCaptureKit — `SCShareableContent` *hangs silently* inside the sandbox
  (a required Mach service is blocked; the call never returns).
- `pytest` — pyannote's `Pipeline.from_pretrained` makes a Hugging Face Hub
  call; inside the sandbox that is routed through a SOCKS proxy httpx can't use.

Bottom line: audio-device capture is sandboxed; build, tests, GPU
transcription, ScreenCaptureKit, and pytest run unsandboxed + allowlisted.
Metal (IOKit) and ScreenCaptureKit could not be made sandbox-safe.

## whisper CPU toggle

`WhisperTranscriber.useGPU` defaults to an environment-aware value: set
`PULSARTRACE_WHISPER_CPU=1` to force whisper's CPU backend process-wide. It is
an escape hatch for GPU-less / sandboxed contexts; production default stays GPU
(Metal). The test suite forces CPU independently via `WhisperTestGate`
(DECISIONS.md D15) — that is unrelated to this toggle.

## Running things

- Build: `swift build`
- Tests: `swift test --filter Unit` · `--filter Pipeline` · `--filter Capture`
- Device tests (opt-in, real hardware):
  `PULSARTRACE_DEVICE_TESTS=1 swift test --filter Capture`
- Python tests: `python/pulsartrace-ai/.venv/bin/pytest python/pulsartrace-ai`
- Audio loopback smoke check: `scripts/audio-loopback-check.sh`

Results at the time of writing: Unit 163/163, Capture 3/3 (+2 device tests pass
when opted in), pytest 15/15, Pipeline 39–40/40 (see Known issue).

## Known issue

`StreamingPipelineTests` "live.md body matches the recorded snapshot" is
**flaky**: under heavy CPU load the streaming pipeline commits far fewer
utterances than the recorded snapshot (observed 1 vs 11), and it passes on a
quiet re-run. The streaming path's real-time pacing + backpressure is
load-sensitive — worth a look as an Epic 6 robustness item. Not a regression
from this session's work.
