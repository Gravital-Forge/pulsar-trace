# PT-P5-E2 · ANE Diarization — Completion Record

**Status:** Frozen · **Closed:** 2026-06-14

## What was built

Speaker diarization now runs fully in-process on the Apple Neural Engine for both passes, and the
embedded-Python pyannote sidecar is gone.

A resident `DiarizerEngine` actor (`Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`)
owns FluidAudio 0.15.2's `OfflineDiarizerManager` and is loaded once per process; the live pass
shares that single instance. The offline `Diarizer` keeps its type name, its
`diarizeSystemStream(wavPath:)` entry point (PT-R17 structurally intact — the mic is never
diarized), and its `RefinementCancellable`, but its mechanism is swapped: cancellation maps onto
Swift `Task`
cancellation (FluidAudio calls `Task.checkCancellation()` in its compute loop, so a queue pause
genuinely stops compute instead of SIGKILLing a subprocess), and the timeout watchdog is kept
(effective timeout = max(600 s, real-time length)). The dominant-overlap transcript⨉turns merge and
30 % co-attribution are unchanged — they operate on the in-process result the same way.

The models are FluidInference's CoreML conversion of `speaker-diarization-community-1` (powerset
segmentation + WeSpeaker 256-d embeddings + AHC warm start + VBx/PLDA refinement), ~21 MB from the
public repo `FluidInference/speaker-diarization-coreml`, downloaded into
`~/Library/Caches/PulsarTrace/models/speaker-diarization/`. `modelRevision` is the `DirectoryDigest`
(PT-P5-E1), carrying the cross-revision-refusal semantics. The one deliberate tuning deviation is
`clustering.warmStartFa = 0.2` (default 0.07), and the thresholds are recalibrated for the WeSpeaker
geometry (`SpeakerLibrary.defaultMatchThreshold` 0.7 → 0.45, `LiveDiarizer.stitchThreshold` 0.55 →
0.45), all pinned by the `DiarizationE2E` calibration suite — see PT-P5-D4.

The live pass keeps its 10 s window / 5 s step geometry and embedding-stitching algorithm
(per-window labels stitched into stable provisional `Them`/`Them #N` keys); only the inference moved
in-process. Because all three paths run the same FluidAudio WeSpeaker model, PT-R29 (one embedding
space across live, offline, and the library) now holds by construction.

The speaker library migrated to schema v3 (`pyannote_model_revision` → `model_revision`; any pre-v3
database is archived to `speakers.sqlite.pre-v3.bak` via `VACUUM INTO` and reset, because
pyannote-space centroids cannot match WeSpeaker embeddings), and `metadata.json` to v2
(`pyannote_model` → `diarization_model { id, revision }`; `library_version` dropped). The entire
`python/` tree was deleted — venv, `requirements.lock`, `pulsartrace_ai` modules, the Swift↔Python
JSON contract, the `HF_TOKEN`/`.env` flow, and the OpenTelemetry kill-switch — and `doctor` now
checks the model cache instead of probing a Python environment.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P5-R6** (in-process ANE offline diarization) —
  `Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`, `Diarizer.swift`,
  `DiarizationResultMapper.swift`, `SpeakerSpan.swift`, `DiarizedTranscript.swift`.
- **PT-P5-R7** (unified WeSpeaker embedding space) — `DiarizerEngine.swift` (one shared
  `OfflineDiarizerManager`); `Sources/PulsarTraceEngine/Streaming/LiveDiarizer.swift`
  (`stitchThreshold`); the Speaker Library (`defaultMatchThreshold`); pinned by the `DiarizationE2E`
  threshold-calibration suite.
- **PT-P5-R8** (diarization-driven schema migration) — the Speaker Library schema-v3 migration
  (`model_revision`; pre-v3 archive-and-reset); the `metadata.json` v2 writer
  (`diarization_model { id, revision }`).
- **PT-P5-R9** (retire the Python diarization test layer) — deletion of the `python/` tree and its
  tests; `doctor` model-cache check.

## To flow into the product layer

At project close-out, reconcile per `references/close-out.md`:

- **Mint** PT-R111 (in-process ANE offline diarization), **superseding** PT-R15a; PT-R112 (unified
  WeSpeaker embedding space), **superseding** PT-R29; PT-R113 (diarization-driven schema migration —
  speaker-library v3, `metadata.json` v2), a fresh introduce.
- **Retire** PT-R67 (the Python diarization test layer); diarization is now covered by Swift tests.
- **Architecture:** rewrite PT-C3 (Diarization Engine) to the in-process FluidAudio CoreML pipeline
  and the resident `DiarizerEngine`; rewrite PT-C13 (Live Diarization) to the in-process per-window
  call (no subprocess); update PT-C5 (Speaker Library) for schema v3 and the WeSpeaker thresholds;
  update PT-C4 (Refinement Pipeline) where it drove the diarizer. Consider whether the resident
  `DiarizerEngine` warrants its own component or folds into PT-C3.
- **Traceability:** two-write supersession rows for PT-R15a→PT-R111 and PT-R29→PT-R112; a
  write-once row for PT-R113; a terminal Retired flip on PT-R67.
- **Reference sweep:** grep for lingering references to PT-R15a / PT-R29 / PT-R67, to `pyannote`,
  and to the Python diarization layer, and resolve each. Note PT-R15/PT-R16/PT-R18 (live diarization
  intent) and PT-R21 (refinement global diarization) are unchanged in intent — only their mechanism
  moved — and stay Active.
