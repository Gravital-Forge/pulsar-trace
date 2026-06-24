# PT-P2-E2 · Real Device Capture — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

The `PulsarTraceCapture` library (with the thin `pulsartrace-capture` daemon) orchestrates capture via
`DeviceCaptureSource`: a `MicCaptureEngine` (AVFoundation) and a `SystemAudioCaptureEngine`
(ScreenCaptureKit), each resampling and downmixing to the canonical 16 kHz mono Float32 at the source
boundary (`AudioConverter`, `SampleBufferConverter`), delivered over two single-stream
`CaptureSocketServer`s the engine consumes as socket sources. The daemon is the only process holding
microphone and screen-recording permissions (`PermissionChecker`). Pause and resume travel in-band as
`FrameProtocol` control frames; `SleepWakeMonitor` drives pause/resume across system sleep, and
`SampleBufferConverter` rebuilds the converter when a later buffer's format differs mid-session (a
device change), with the live transcript annotating the gap. The mic can be chosen and system audio
disabled. Recording-lifecycle and permission events are emitted by the daemon.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P2-R4** — `Sources/PulsarTraceCapture/` — `DeviceCaptureSource.swift`,
  `MicCaptureEngine.swift`, `SystemAudioCaptureEngine.swift`, `AudioConverter.swift`,
  `SampleBufferConverter.swift`, `CaptureSocketServer.swift`, `AudioInputDevices.swift`
- **PT-P2-R5** — `Sources/PulsarTraceCapture/PermissionChecker.swift`
- **PT-P2-R6** — `Sources/PulsarTraceCapture/SleepWakeMonitor.swift` (sleep),
  `SampleBufferConverter.swift` (device-format change);
  `Sources/PulsarTraceEngine/IPC/FrameProtocol.swift`

## To flow into the product layer

- Mint components: Capture Daemon; extend the IPC layer with the in-band pause/resume control frames;
  extend the Events Log contract with recording-lifecycle and permission events.
- Mint product requirements PT-R1, PT-R2, PT-R3, PT-R5, PT-R6, PT-R74 (capture); PT-R4 (sole
  permissioned process); PT-R7, PT-R8, PT-R77 (survive interruptions).
