# PulsarTrace

Local-only macOS meeting transcription and speaker diarization. Records
meetings, transcribes them with whisper.cpp, diarizes them with pyannote, and
writes speaker-labeled Markdown plus a machine-readable JSONL events log. No
telemetry, no in-app LLM, no cloud — you plug your own AI agent into the files.

> **Status: Epic 1 (Foundations) — in development.** This is the infrastructure
> layer: the `AudioFrameSource` abstraction, logging, the events log, IPC
> scaffolding, and the test harness. Transcription, diarization, and the
> `refine` CLI land in Epics 2–5.

## Layout

```
Package.swift                 SwiftPM package (pure SwiftPM, no Xcode project)
Sources/
  PulsarTraceEngine/          Core library: sources, engine, logging, events, IPC
  pulsartrace-engine/         The streaming engine binary
  pulsartrace/                The user-facing CLI
Tests/
  UnitTests/                  Layer 1: pure-logic unit tests (<5s)
  PipelineTests/              Layer 2 + 4: fixture-fed pipeline + IPC tests
  CaptureTests/               Layer 3: real-device capture tests (need BlackHole)
  Fixtures/audio/             Committed 16kHz mono WAV fixtures
python/
  pulsartrace-ai/             Python diarization layer (pyannote/diart) — Epic 3
  build-venv.sh               Builds the dev venv from Homebrew python3.12
docs/
  file-format.md              live.md / final.md format contract
  events-schema.md            Events log schema contract
  release-smoke-test.md       Manual pre-release checklist
```

## Building and testing

```sh
swift build                       # build the package
swift test --filter Unit           # fast unit tests
swift test --filter Pipeline       # fixture-fed pipeline + IPC tests
swift test --filter Pipeline.IPC   # just the IPC integration tests
swift test --filter Capture        # capture tests (skip cleanly without BlackHole)

python/build-venv.sh                                   # build the Python venv
python/pulsartrace-ai/.venv/bin/pytest                 # run Python tests
```

## Architecture

Everything in the engine consumes one abstraction — `AudioFrameSource`, an
`AsyncSequence` of 16 kHz mono Float32 PCM frames at 20 ms framing. The engine
cannot tell whether frames came from a real device, a fixture WAV, stdin, or a
Unix socket. This is what makes the pipeline testable without audio hardware.

End-to-end pipe smoke test:

```sh
ffmpeg -re -i Tests/Fixtures/audio/single-speaker-30s.wav -f f32le -ac 1 -ar 16000 - \
  | .build/debug/pulsartrace-engine --stdin
```

## License

MIT.
