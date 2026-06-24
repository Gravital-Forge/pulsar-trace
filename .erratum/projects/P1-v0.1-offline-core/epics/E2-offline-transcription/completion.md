# PT-P1-E2 · Offline Transcription — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

Transcription runs on a resident native recognizer (whisper.cpp, vendored from source at a pinned
version, built with Metal, linked through the `CWhisper` C-interop target) wrapped by
`WhisperTranscriber`. `OfflineTranscriptionPipeline` transcribes a whole stream in a single pass —
so there are no chunk-boundary artifacts — applying `BlankTokenFilter` and a no-speech threshold,
and emits `TranscriptDocument`: a header plus per-utterance `**[HH:MM:SS] Speaker:** text` lines
with seconds-since-start timestamps.

`ModelStore` downloads recognition models with HTTP range-resume and verifies them against pinned
SHA-256 hashes (`SHA256Verifier`) before use, deleting and retrying on mismatch, and emits a
model-download event; `ModelCatalog` pins the multilingual default and refinement models. `WAVWriter`
/ `WAVReader` read and write the canonical 16 kHz mono Int16 PCM WAV.

## Deltas from the spec

None. Determinism was confirmed across repeated runs; concurrent recognizer use is serialized by a
process-wide lock (recorded as PT-P1-D8).

## Requirements satisfied

- **PT-P1-R2** — `Sources/PulsarTraceEngine/Transcription/` — `WhisperTranscriber.swift`,
  `OfflineTranscriptionPipeline.swift`, `TranscriptDocument.swift`, `BlankTokenFilter.swift`,
  `WhisperOptions.swift`; `CWhisper` interop
- **PT-P1-R3** — `Sources/PulsarTraceEngine/Transcription/` — `ModelStore.swift`, `ModelCatalog.swift`, `SHA256Verifier.swift`
- **PT-P1-R4** — `Sources/PulsarTraceEngine/Audio/` — `WAVWriter.swift`, `WAVReader.swift`

## To flow into the product layer

- Mint component: Transcription Engine (offline path).
- Mint product requirements PT-R9 (resident transcription), PT-R13 (transcript line format), PT-R54c
  (resumable download), PT-R54d (hash verification), PT-R54e (canonical WAV storage).
