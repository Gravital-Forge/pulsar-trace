# PT-P2-E5 · Capture & Transcript Correctness — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

Two correctness fronts surfaced by the first real recordings.

Offline decoding: the refine pass moved to a small non-zero decode temperature with a fallback
ladder plus voice-activity gating to escape silence-induced repetition loops, then to detecting
speech regions, coalescing those within a small gap, and decoding each region as its own call —
fixing a cross-turn ordering bug where concatenated speech glued multi-turn monologues into one
mis-sorted segment. `HallucinationFilter` drops a stock silence-hallucination phrase only when an
objective per-segment confidence signal also indicates silence, so a real utterance is never dropped
on phrase text alone. (Offline path only; the live pass keeps deterministic zero-temperature
decoding.)

Capture: a layout-less stereo device format was repaired so the downmixer produces non-silent mono,
restoring microphone capture — hardening PT-P2-R4.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P2-R13** — `Sources/PulsarTraceEngine/Transcription/` — `WhisperTranscriber.swift`,
  `RegionTranscribing.swift` (temperature ladder + per-region decode), `HallucinationFilter.swift`;
  `Refinement/RefinementPipeline.swift` (region merge/ordering)
- **PT-P2-R4 (hardening)** — `Sources/PulsarTraceCapture/AudioConverter.swift` — device-format
  downmix repair

## To flow into the product layer

- Update the Transcription Engine and Refinement Pipeline component descriptions with the
  region-based decode and the hallucination gate; note the capture downmix repair on the Capture
  Daemon.
- Mint product requirement PT-R91 (robust offline decoding).
