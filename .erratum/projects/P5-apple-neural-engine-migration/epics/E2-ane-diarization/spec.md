# PT-P5-E2 · ANE Diarization — Specification

**Status:** Frozen · **Opened:** 2026-06-13 · **Closed:** 2026-06-14

## Intent

Move speaker diarization fully in-process onto the Apple Neural Engine and remove the embedded-Python
pyannote sidecar. Implements PT-P5-R6 (in-process ANE offline diarization), PT-P5-R7 (unified
WeSpeaker embedding space), PT-P5-R8 (diarization-driven schema migration), and PT-P5-R9 (retire the
Python diarization test layer). Reshapes the Diarization Engine (PT-C3), Live Diarization (PT-C13),
the Speaker Library (PT-C5), and the Refinement Pipeline (PT-C4); deletes the `python/` tree.

## Acceptance criteria

- Both the offline (refine) and live (streaming) passes diarize the system stream through FluidAudio's
  CoreML `speaker-diarization-community-1` pipeline in-process on the ANE; the microphone stream is
  never diarized.
- A resident `DiarizerEngine` actor owns the `OfflineDiarizerManager`, loaded once per process and
  shared by the live pass; the offline `Diarizer` keeps the `diarizeSystemStream(wavPath:)` entry
  point and `RefinementCancellable`, with cancellation mapped onto Swift `Task` cancellation.
- Live, offline, and library embeddings come from one FluidAudio WeSpeaker model (R29 holds by
  construction); `clustering.warmStartFa = 0.2`, `SpeakerLibrary.defaultMatchThreshold = 0.45`, and
  `LiveDiarizer.stitchThreshold = 0.45`, all pinned by the threshold-calibration tests.
- `modelRevision` is the `DirectoryDigest` of the model directory; the library refuses to match
  centroids across a `modelRevision` change.
- The speaker library migrates to schema v3 (archive-and-reset of any pre-v3 database);
  `metadata.json` migrates to v2 (`diarization_model { id, revision }`; `library_version` dropped).
- No `python/` tree, venv, `requirements.lock`, `pulsartrace_ai` module, Swift↔Python JSON contract,
  or `HF_TOKEN`/`.env` flow remains; `doctor` checks the model cache instead of a Python environment.

## Tasks

- PT-P5-E2-T1 — Resident `DiarizerEngine` over FluidAudio's `OfflineDiarizerManager`; the live pass
  shares the single resident instance.
- PT-P5-E2-T2 — Cut the offline `Diarizer` over to in-process FluidAudio (same entry point; `Task`
  cancellation; timeout watchdog kept).
- PT-P5-E2-T3 — Cut the live pass over to the in-process engine (10 s / 5 s geometry and
  embedding-stitching unchanged; per-window inference now in-process).
- PT-P5-E2-T4 — VBx `warmStartFa = 0.2` and WeSpeaker-space thresholds, pinned by the
  `DiarizationE2E` calibration suite.
- PT-P5-E2-T5 — Speaker-library schema v3 (`model_revision`; pre-v3 archive-and-reset) and
  `metadata.json` v2 (`diarization_model { id, revision }`).
- PT-P5-E2-T6 — Delete the `python/` tree and its tests; repoint `doctor` to the model cache.
