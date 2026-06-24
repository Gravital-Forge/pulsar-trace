# PT-P2-E1 · Streaming & Live Diarization — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

`StreamingTranscriber` holds an anchored window over the system stream and a LocalAgreement-2
committer (`LiveAgreementCommitter`) that emits only utterances two successive decodes agree on, so
the live transcript never revises a word; backpressure advances the anchor. `StreamingPipeline`
wires the live run. `LiveMarkdownWriter` writes the live transcript strictly append-only — created
at session start with its provisional marker and header, growing monotonically with atomic per-line
appends. `LiveDiarizer` runs the diarization pipeline over a sliding window via a long-lived
subprocess, stitching provisional speaker keys across windows by embedding similarity, and looks up
the speaker library read-only to surface known names (still marked provisional); the library is
never written by the live pass. `MicEchoDedup` drops system-side duplicates of mic speech by text
similarity within a small window. The engine gains a `--live` mode that also writes the system WAV
so a later refine works.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P2-R1** — `Sources/PulsarTraceEngine/Streaming/` — `StreamingTranscriber.swift`,
  `LiveAgreementCommitter.swift`, `StreamingPipeline.swift`, `LiveMarkdownWriter.swift`
- **PT-P2-R2** — `Sources/PulsarTraceEngine/Streaming/` — `LiveDiarizer.swift`, `DiarState.swift`,
  `DiarBufferManager.swift`
- **PT-P2-R3** — `Sources/PulsarTraceEngine/Streaming/MicEchoDedup.swift`

## To flow into the product layer

- Mint components: Streaming Transcription, Live Diarization, Live Markdown Writer; extend the
  Transcript Output contract with the provisional live stream, its marker, and append-only
  discipline.
- Mint product requirements PT-R10, PT-R11, PT-R12, PT-R14, PT-R35, PT-R35a, PT-R36, PT-R37 (live
  transcript); PT-R15, PT-R16, PT-R18, PT-R32 (live diarization); PT-R19 (mic-echo dedup).
