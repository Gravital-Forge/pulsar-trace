# PT-P5 · Apple Neural Engine Migration — Project PRD

**Status:** Open · **Opened:** 2026-06-12

<!-- Open while in progress; gains a **Closed:** date and Status Frozen at close-out, when the ANE
     branch merges to main and the change-types below are reconciled into the product layer. -->

## Scope

This project moves PulsarTrace's two compute-heavy passes — transcription and diarization — off the
GPU/Metal and embedded-Python stacks and onto the Apple Neural Engine, in-process. The live pass
transcribes with Parakeet TDT 0.6B v3 (FluidAudio) and the refine pass with WhisperKit
(`large-v3-turbo`, with `large-v3` as an accuracy fallback); both run on the ANE. Diarization runs
FluidAudio's CoreML conversion of the `speaker-diarization-community-1` pipeline in-process on the
ANE for both the offline and the live passes. Two stacks are removed wholesale: whisper.cpp (the
`CWhisper` interop, the vendored Metal build, the `pulsartrace-whisper` out-of-process recognizer,
`WhisperIPC`, `ModelStore`/`ModelCatalog`) and the embedded-Python pyannote sidecar (the entire
`python/` tree, its venv and pin set, the one-shot and windowed subprocesses, the Swift↔Python JSON
contract, and the Hugging Face token/gating flow). Model integrity moves from a pinned content-hash
gate to a computed content digest (`DirectoryDigest`) over SDK-managed CoreML bundle directories.

The recognition and diarization **intent** is preserved; the mechanisms change. The project leaves
the capture, refinement-orchestration, events-log, menubar, and security layers as the P4 baseline
left them, except where the new embedding space forces a schema bump (speaker-library v3,
`metadata.json` v2) and where removing the out-of-process recognizer changes how a wedged decode is
recovered (now an in-process, deadline-bounded cancellation).

After the diarization cutover, two reliability **revisions** of the diarization epic follow — a
live-diarizer over-split investigation (E2-rev1) and a live-diarization wedge-reliability
investigation (E2-rev2). The latter is the project's genuinely in-flight tail.

## Project Requirements

Each requirement carries a **type** (functional / technical / constraint) and a **change-type**
against the product layer (Introduce / Supersede(target) / Retire(target)), with the target product
requirement in the heading. These are **mutable drafts** until close-out: the new product
requirement numbers below are marked **(draft)** because minting, supersession pointers, and
terminal flips are executed against `product/` only at project close-out (when this branch merges to
main), per `references/close-out.md`. The reliability revisions E2-rev1 and E2-rev2 propose **no new
product requirement** — E2-rev1's experiment was reverted, and E2-rev2 hardens existing live-pass
guarantees rather than adding one.

### PT-P5-R1 · Technical · Supersede(PT-R9) — Resident ANE transcription

The engine transcribes a complete audio stream with recognition models held resident on the Apple
Neural Engine: Parakeet TDT 0.6B v3 (FluidAudio) for the live pass and WhisperKit (`large-v3-turbo`
default, `large-v3` accuracy fallback) for the refine pass. There is no live-model knob anywhere;
the refine model is a Settings/flag choice over a fixed two-model catalog.

*Supersedes:* PT-R9; introduces PT-R107 (draft). *Acceptance:* a fixture transcribes through the ANE
backends with no whisper.cpp dependency present; `recording_started.model_live` is fixed to
`parakeet-v3`; the refine model switches via Settings without code change.

### PT-P5-R2 · Technical · Supersede(PT-R54c) — SDK-managed model acquisition

Recognition and diarization models are CoreML bundles fetched by their own SDKs (WhisperKit,
FluidAudio) into the single product-owned cache root; PulsarTrace no longer owns an HTTP-range
resumable downloader.

*Supersedes:* PT-R54c; introduces PT-R108 (draft). *Acceptance:* models download via the SDKs into
`~/Library/Caches/PulsarTrace/models/`; no PulsarTrace-owned range-request download path remains.

### PT-P5-R3 · Technical · Supersede(PT-R54d) — Content-digest model integrity

A downloaded model bundle's identity is a deterministic `DirectoryDigest` (a SHA-256 tree hash of
the bundle directory) carried on the `model_downloaded` event, instead of verification against a
pinned content hash. An upstream bundle revision changes the digest rather than hard-failing a
mismatch.

*Supersedes:* PT-R54d; introduces PT-R109 (draft). *Acceptance:* `model_downloaded` carries a
`DirectoryDigest`; no pinned-SHA verification gate remains; `RefinementJob.modelSHA256` and the
`metadata.json` hash field record `""` for SDK-managed bundles.

### PT-P5-R4 · Technical · Introduce — In-process ANE-bounded decode recovery

A wedged or runaway ANE decode cannot stall or lose the recording, the live transcript, or the audio
file, and is recovered in-process: a refine decode stops at a WhisperKit per-token callback deadline,
and the paused job drops the WhisperKit actor (ARC frees the CoreML models) and requeues from its
on-disk checkpoint; a live Parakeet window is bounded by a per-window semaphore deadline and skipped,
with the post-pass recovering it.

*Introduces:* PT-R110 (draft). *Acceptance:* a hung refine decode is cancelled at a token boundary
and resumes from checkpoint; a hung live window is skipped without stalling the drain or the WAV
writes.

### PT-P5-R5 · Functional · Retire(PT-R97) — Out-of-process recognizer removed

The `pulsartrace-whisper` subprocess and the requirement that a wedged decode be recovered by
force-killing an external recognizer process are retired; the in-process deadline-bounded recovery
of PT-P5-R4 replaces the process-isolation mechanism.

*Retires:* PT-R97, and retires component PT-C19 (Out-of-Process Recognizer). *Acceptance:* no
`pulsartrace-whisper` target, `WhisperIPC`, or `RemoteTranscriberCore` remains; the live drain and
refine queue invoke the recognizer in-process.

### PT-P5-R6 · Functional · Supersede(PT-R15a) — In-process ANE offline diarization

The system stream is diarized offline by FluidAudio's CoreML `speaker-diarization-community-1`
pipeline running in-process on the Apple Neural Engine — powerset segmentation, WeSpeaker
embeddings, AHC warm start, and VBx/PLDA refinement — replacing the pyannote Python subprocess.

*Supersedes:* PT-R15a; introduces PT-R111 (draft). *Acceptance:* a refine diarizes the system stream
through FluidAudio in-process; no `python/` tree, venv, or pyannote subprocess remains; the mic
stream is still never diarized.

### PT-P5-R7 · Technical · Supersede(PT-R29) — Unified WeSpeaker embedding space

Per-speaker voice embeddings are 256-d WeSpeaker vectors produced by the one FluidAudio pipeline used
across the live pass, the offline pass, and the speaker library — a single embedding space by
construction, with match/stitch thresholds recalibrated to that geometry.

*Supersedes:* PT-R29; introduces PT-R112 (draft). *Acceptance:* live, offline, and library embeddings
come from one FluidAudio WeSpeaker model; `SpeakerLibrary.defaultMatchThreshold` and
`LiveDiarizer.stitchThreshold` are calibrated for it and pinned by the threshold-calibration tests.

### PT-P5-R8 · Technical · Introduce — Diarization-driven schema migration

The new embedding space forces a one-way data migration: the speaker library moves to schema v3
(`pyannote_model_revision` → `model_revision`; a pre-v3 database is archived to
`speakers.sqlite.pre-v3.bak` and reset, because pyannote-space centroids can never match WeSpeaker
embeddings), and `metadata.json` moves to v2 (`pyannote_model` → `diarization_model { id, revision }`;
the `library_version` field is dropped).

*Introduces:* PT-R113 (draft). *Acceptance:* opening a pre-v3 library archives and resets it; a fresh
refine writes `diarization_model { id, revision }` into a v2 `metadata.json`.

### PT-P5-R9 · Technical · Retire(PT-R67) — Python diarization test layer removed

Deleting the `python/` tree removes the pyannote wrapper layer and the Python test layer that covered
it; in-process Swift diarization is covered by the existing Swift test requirements (the
`DiarizationE2E` suite and the deterministic pipeline tests).

*Retires:* PT-R67. *Acceptance:* no `python/` tree or Python test target remains; diarization is
covered by Swift tests, including the threshold-calibration suite.
