# PT-P5-E1 · ANE Transcription Pipeline — Specification

**Status:** Frozen · **Opened:** 2026-06-12 · **Closed:** 2026-06-13

## Intent

Move both transcription passes onto the Apple Neural Engine, in-process, and remove whisper.cpp.
Implements PT-P5-R1 (resident ANE transcription — Parakeet live, WhisperKit refine), PT-P5-R2
(SDK-managed model acquisition), PT-P5-R3 (content-digest model integrity), PT-P5-R4 (in-process
ANE-bounded decode recovery), and PT-P5-R5 (retire the out-of-process recognizer). Reshapes the
Transcription Engine (PT-C2), Streaming Transcription (PT-C12), the Refinement Pipeline / Job Queue
(PT-C4 / PT-C17), the CLI (PT-C9), and the Menubar settings (PT-C16); retires the Model Store
(PT-C10) and the Out-of-Process Recognizer (PT-C19).

## Acceptance criteria

- The live pass transcribes with a resident Parakeet TDT 0.6B v3 model on the ANE (FluidAudio);
  there is no live-model knob anywhere, and `recording_started.model_live` is fixed to
  `parakeet-v3`.
- The refine pass transcribes with WhisperKit on the ANE over a fixed two-model catalog
  (`large-v3-turbo` default, `large-v3` fallback), switchable in Settings and via `refine --model` /
  `record --refine-model`.
- Speech regions come from FluidAudio's Silero-CoreML VAD with 800 ms coalescing, and the D31
  hallucination double-gate is applied on WhisperKit's per-segment `noSpeechProb`/`avgLogprob`.
- Model bundles are SDK-managed directories under `~/Library/Caches/PulsarTrace/models/`;
  `model_downloaded` carries a `DirectoryDigest` and no pinned-SHA gate remains.
- A wedged refine decode is cancelled at a WhisperKit token-callback boundary and the job resumes
  from its checkpoint; a wedged live window is bounded by a per-window deadline and skipped.
- whisper.cpp is absent: no `CWhisper`, vendored Metal build, `pulsartrace-whisper`, `WhisperIPC`,
  `WhisperTranscriber`, or `ModelStore`/`ModelCatalog`.

## Tasks

- PT-P5-E1-T1 — Add FluidAudio 0.15.2 + argmax-oss-swift 1.0.0; relocate the shared transcript and
  option/error types (`TranscriptTypes`, `TranscriptionOptions`/`TranscriptionError`; drop
  `AbortToken`).
- PT-P5-E1-T2 — `DirectoryDigest` content-addressed model identity for CoreML bundles.
- PT-P5-E1-T3 — Parakeet live backend (`ParakeetEngine`, `ParakeetTokenMapper`,
  `ParakeetWindowTranscriber`); cut the live pass over with no model knob.
- PT-P5-E1-T4 — WhisperKit refine backend (`WhisperKitModelCatalog`, `WhisperKitLanguagePolicy`,
  `WhisperKitSegmentMapper`, `WhisperKitRegionTranscriber`) plus `FluidVADRegionDetector`; port the
  D31 hallucination gate.
- PT-P5-E1-T5 — Refine queue, `refine`/`record` CLI, and Menubar settings cutover: in-process decode
  cancel, refine-model picker, removal of the live-model knob.
- PT-P5-E1-T6 — Remove whisper.cpp (`CWhisper`, `pulsartrace-whisper`, `WhisperIPC`,
  `ModelStore`/`ModelCatalog`, the vendored build) and run the rename sweep.
