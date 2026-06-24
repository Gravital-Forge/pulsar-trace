# PT-P1-E3 · Offline Diarization — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

Offline diarization runs the pyannote community-1 pipeline as a one-shot Python subprocess
(`python/pulsartrace-ai`), driven from Swift by `Diarizer` with a timeout and stderr captured to the
operational log. The subprocess returns speaker turns, per-speaker 256-dimension embeddings, and a
model-revision string as JSON; `DiarizationJSON` decodes it under a versioned `schema` field.
`SpeakerSpan` / `DiarizedTranscript` carry the turns, and the transcript-to-turns merge attributes
each utterance to the speaker with dominant time overlap, co-attributing a second speaker that
covers a large minority. The microphone stream is never passed to diarization — mic speech is always
the local speaker.

The library's default-on telemetry exporter is force-disabled (environment guard before import plus
an explicit call, with the guard also injected from the Swift side), keeping the local-only
constraint intact; the model is cached under a single PulsarTrace-owned cache root.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P1-R5** — `Sources/PulsarTraceEngine/Diarization/` — `Diarizer.swift`,
  `DiarizationJSON.swift`, `SpeakerSpan.swift`, `DiarizedTranscript.swift`; `python/pulsartrace-ai`
  diarization script
- **PT-P1-R11** — `python/pulsartrace-ai` telemetry-exporter guard; no off-device transmission
  anywhere in the engine
- **PT-P1-R10 (PT-R67)** — `python/pulsartrace-ai` diarization-wrapper tests (pytest)

## To flow into the product layer

- Mint component: Diarization Engine (offline path).
- Mint product requirements PT-R15a (offline diarization of system stream), PT-R17 (mic never
  diarized), PT-R29 (embeddings from the diarization pipeline), PT-R87 (local-only operation), and
  PT-R67 (the Python diarization-wrapper test layer).
