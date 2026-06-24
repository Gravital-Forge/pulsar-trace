# PT-P3-E4 · Live-Pipeline Decoupling & Wedge Recovery — Completion Record

**Status:** Frozen · **Closed:** 2026-05-29

## What was built

`LiveRunner` was split into a recording-safe drain — WAV writing, diarization, and a bounded
drop-oldest queue (`BoundedFrameQueue`), never calling the recognizer — and a best-effort decode
worker that offloads decoding behind a decode watchdog and abort token (`AbortToken`), so a hung
decode can no longer lose the recording. Because a native decode can wedge below the level an
in-process abort can interrupt, inference then moved out of process: a `pulsartrace-whisper`
subprocess hosts the recognizer over a length-prefixed IPC codec (`WhisperIPC` —
`WhisperSubprocessHost`, `RemoteWindowTranscriber`, `RemoteRegionTranscriber`,
`RemoteTranscriberCore`, `SerializingHostProxy`, `WhisperFrameCodec`), with parent-side wedge
detection that force-kills and respawns the subprocess.

## Deltas from the spec

The decode-isolation goal was reached in two steps: the in-process drain/worker split (recording
safety) and then the out-of-process recognizer (true wedge recovery), the latter because the
in-process abort path proved insufficient (PT-P3-D9).

## Requirements satisfied

- **PT-P3-R5** — `Sources/PulsarTraceEngine/Streaming/` — `LiveRunner.swift`,
  `BoundedFrameQueue.swift`, `LiveSink.swift`; `Sources/PulsarTraceEngine/WhisperIPC/`;
  `Sources/pulsartrace-whisper/main.swift`

## To flow into the product layer

- Extend the Recording Durability component with the drain/worker split; mint an Out-of-Process
  Recognizer component for the kill-able subprocess host.
- Mint product requirement PT-R97 (recording isolated from decode hangs).
