# PT-P1-E1 · Foundations — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

A SwiftPM package with the `PulsarTraceEngine` library, the `pulsartrace-engine` executable, and the
`pulsartrace` CLI executable, plus Unit / Pipeline / Capture test targets.

The audio seam is `AudioFrameSource` — an `AsyncSequence` of fixed-format `AudioFrame`s (16 kHz mono
Float32, 20 ms / 320 samples) — with `FixturePlaybackSource` (real-time-paced WAV playback, with a
fast mode), `PipeSource` / `RawPCMPipeSource` (frames from a file descriptor), and `SocketSource`
(frames from a Unix socket). All emit a uniform end-of-stream.

Operational logging is a dual `swift-log` backend (system log + a rotating file handler with
multi-day retention) with a content-leak scanner asserting no audio, transcript, names, or full
paths reach the log. The events log is a JSONL writer with a ULID-stamped common envelope, an event
registry, daily rotation, and retention. The IPC layer defines the control and binary-frame
protocols used later by capture. ULIDs and path resolution live in `Support`.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P1-R1** — `Sources/PulsarTraceEngine/Audio/` — `AudioFrameSource.swift`, `AudioFrame.swift`,
  `FixturePlaybackSource.swift`, `PipeSource.swift`, `RawPCMPipeSource.swift`, `SocketSource.swift`
- **PT-P1-R8** — `Sources/PulsarTraceEngine/Events/` — `Event.swift`, `EventRegistry.swift`,
  `EventWriter.swift`; `Support/ULID.swift`
- **PT-P1-R9** — `Sources/PulsarTraceEngine/Logging/` — `Logging.swift`, `FileLogHandler.swift`,
  `LogRotator.swift`, `OSLogHandler.swift`; `Support/ContentLeakScanner.swift`
- **PT-P1-R10** — `Tests/UnitTests/`, `Tests/PipelineTests/`, `python/pulsartrace-ai` pytest;
  fixtures under `Tests/Fixtures/audio/`
- **PT-P1-R12** — package manifest `Package.swift` — open-source dependency set
- **PT-P1-R13** — `Sources/PulsarTraceEngine/Events/` envelope `version` field (events contract);
  transcript contract carried by PT-P1-E4

## To flow into the product layer

- Mint components: Audio Source Layer, Events Log, Operational Logging, IPC Layer.
- Mint product requirements PT-R70–R73, R75, R76 (sources); R78–R82, R84, R85 (events); R57–R61
  (logging); R62–R65, R67a (tests); R88 (open-source-only); R89 (versioned contracts).
