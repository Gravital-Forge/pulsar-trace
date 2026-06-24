# PT-P2-E2 · Real Device Capture — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Capture real audio devices behind the same source protocol (PT-P2-R4), as the sole permissioned
process (PT-P2-R5), surviving sleep and device change (PT-P2-R6). Implements the device source
(PT-C1) and rides the IPC layer (PT-C8); emits recording-lifecycle events (PT-C6).

## Acceptance criteria

- A real mic + system-audio capture, resampled/downmixed at the source, feeds the engine over two
  sockets and produces a live transcript.
- Only the capture daemon holds OS permissions.
- Sleep and a mid-session device change annotate a gap and resume; system audio is optional.

## Tasks

- PT-P2-E2-T1 — `PulsarTraceCapture` library + thin daemon; two single-stream socket servers
- PT-P2-E2-T2 — Mic (AVFoundation) + system (ScreenCaptureKit) engines; resample/downmix at source
- PT-P2-E2-T3 — In-band pause/resume control frames; sleep/wake + device-change recovery
- PT-P2-E2-T4 — Permission checking confined to the daemon; recording-lifecycle events
