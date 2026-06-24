# PT-P3-E1 · Live-Recording Resilience — Completion Record

**Status:** Frozen · **Closed:** 2026-05-18

## What was built

`StreamingWAVWriter` streams the recording WAV to disk frame-by-frame, re-patching the RIFF header so
the on-disk file is always a valid, refine-able WAV — capping loss at about a second on a hard kill,
replacing the prior in-RAM end-of-run dump. Each capture engine runs a `FrameWatchdog` (a few seconds
without audio) whose firing has `DeviceCaptureSource` rebuild just that engine with capped exponential
backoff, surfaced through the existing pause/resume frames with a stall-recovery reason; an engine-side
silence backstop tolerates daemon death. The live diarizer was moved off the run-loop critical path —
a bounded buffer (`DiarBufferManager`) and a `DiarGate` actor cap one window in flight — so a stuck
diarize can no longer stall transcription, the WAV, or the live transcript.

## Deltas from the spec

None.

## Requirements satisfied

| Project Requirement | Where |
| ------------------- | ----- |
| PT-P3-R1 | `Sources/PulsarTraceEngine/Audio/StreamingWAVWriter.swift`; `Sources/PulsarTraceEngine/Streaming/LiveRunner.swift` |
| PT-P3-R2 | `Sources/PulsarTraceCapture/FrameWatchdog.swift`, `DeviceCaptureSource.swift` |

## To flow into the product layer

- Mint a Recording Durability component covering incremental WAV writing and the live-pipeline
  isolation; update the Capture Daemon with stall detection/auto-restart.
- Mint product requirements PT-R92 (crash-safe recording), PT-R93 (capture stall recovery).
