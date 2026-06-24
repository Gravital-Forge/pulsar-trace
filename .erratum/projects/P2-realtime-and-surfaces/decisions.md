# PT-P2 · Real-Time & Surfaces — Decision Log

The choices behind the live pass, device capture, the CLI, and the menubar. Frozen at project close.

## Decisions

### PT-P2-D1 · Live diarization by windowed pipeline, not a streaming library

*2026-05-16*

**Decision:** Live diarization runs the same diarization pipeline as the offline pass over a sliding
window via a long-lived subprocess, stitching speaker identity across windows by embedding similarity.

**Because:** The obvious streaming-diarization library would force a downgrade of the diarization
model that breaks the offline pass; a windowed run of the pinned model keeps one model across both
passes.

### PT-P2-D2 · Streaming: anchored window plus a two-pass agreement committer

*2026-05-16*

**Decision:** Live transcription holds an anchored window (fixed start, growing end) and commits only
text that two successive decodes agree on; under backpressure the anchor jumps forward.

**Because:** Committing only agreed text keeps the live transcript strictly append-only — no word is
ever revised — while the anchored window bounds decode cost.

### PT-P2-D3 · Pause/resume as in-band control frames

*2026-05-16*

**Decision:** Capture pause and resume travel in-band on the audio socket as control frames
distinguished by length, additive to the frame protocol.

**Because:** One channel for audio and control keeps the capture/engine boundary simple and backward
compatible.

### PT-P2-D4 · Capture as a library plus a thin daemon

*2026-05-16*

**Decision:** Device-capture code lives in a `PulsarTraceCapture` library used by both the daemon
executable and the capture tests, depending on the engine for shared wire types; no separate IPC
module.

**Because:** A library is testable without the executable, and reusing the engine's wire types avoids
a third module.

### PT-P2-D5 · CLI before menubar; orchestration in the engine

*2026-05-16*

**Decision:** The operator CLI was built before the menubar, and `record` orchestration lives in an
engine-side `RecordOrchestrator` that spawns capture and the live engine as subprocesses; the CLI
stays settings-agnostic.

**Because:** A headless orchestrator is testable against stand-in daemons and is reused later by the
menubar, so it belongs in the engine, not the CLI or the UI.

### PT-P2-D6 · `record --output` is a directory; one model knob

*2026-05-16*

**Decision:** `record --output` names the recording-folder directory, and a single `--model` applies
to both the live and refine passes (defaulting small to avoid a surprise large-model download).

**Because:** A directory is the natural unit for a recording's artifacts, and one conservative model
knob avoids an unexpected multi-gigabyte download from a headless command.

### PT-P2-D7 · Offline refine: non-zero temperature plus voice-activity gating

*2026-05-16*

**Decision:** The offline refine pass decodes at a small non-zero temperature with a fallback ladder
and a voice-activity gate; the live pass keeps deterministic zero-temperature decoding.

**Because:** Long digital silence drove the greedy decoder into repetition loops; a temperature
ladder and silence gating escape them, while a fixed-seed sampler keeps refine reproducible.

### PT-P2-D8 · Offline refine: decode per voice-activity region

*2026-05-16*

**Decision:** Refine detects speech regions, coalesces those within a small gap, and decodes each
region as its own call rather than the whole stream at once.

**Because:** Concatenating speech across pauses glued multi-turn monologues into one segment that
sorted ahead of the other speaker; per-region decoding fixes the cross-turn ordering.

### PT-P2-D9 · Menubar layout; passive global hotkey

*2026-05-16*

**Decision:** Menubar logic lives in a `PulsarTraceMenuBar` library behind a thin SwiftUI executable
(no Xcode project), and the global hotkey uses a passive event monitor.

**Because:** A library keeps the UI logic testable, and a passive monitor avoids requesting the broad
accessibility permission an active hotkey would need.

### PT-P2-D10 · Menubar refines in-process

*2026-05-16*

**Decision:** The menubar runs refinement in-process through a shared offline refiner rather than
shelling out to the CLI.

**Because:** Shelling out hid failures and duplicated logic; in-process refine surfaces errors as
thrown exceptions and shares one code path with the CLI.

### PT-P2-D11 · Menubar separates live and refine models

*2026-05-16*

**Decision:** The menubar exposes distinct live-model and refine-model settings, both defaulting
small.

**Because:** An interactive picker has no surprise-download risk, and the two passes have genuinely
different latency/quality trade-offs.

### PT-P2-D12 · Output folder stored as a plain path

*2026-05-16*

**Decision:** The menubar stores the chosen output folder as a plain path string, not a
security-scoped bookmark.

**Because:** Bookmarks are an app-sandbox mechanism; in the unsandboxed app they went stale across
rebuilds and lost the selection.

### PT-P2-D13 · Hallucination filter gated on phrase and confidence

*2026-05-16*

**Decision:** The offline pass drops a segment only when it matches a known silence-hallucination
phrase and an objective confidence signal also indicates silence; a phrase match alone never drops.

**Because:** Dropping on phrase text alone would discard real utterances; requiring an objective
silence signal makes the filter safe.
