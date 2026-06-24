# PT-P1 · v0.1 Offline Core — Project PRD

**Status:** Frozen · **Opened:** 2026-05-15 · **Closed:** 2026-05-16

## Scope

This project establishes PulsarTrace as a local-only, offline transcription pipeline shipped as a
command-line tool — the v0.1 product. It introduces the audio-source abstraction every later
capability builds on, an offline transcription engine, offline speaker diarization, a
post-recording refinement pass that produces the authoritative transcript, and a persistent speaker
library that carries speaker identity across recordings. It also lays down the cross-cutting
foundations: an append-only machine-readable events log, content-safe operational logging, and a
deterministic layered test strategy.

Real audio-device capture, live/streaming transcription, the menubar UI, and the full operator CLI
are deliberately out of scope; this project consumes audio only through file, pipe, and socket
sources and emits transcripts to disk. The product is exercised end-to-end by feeding a recording
through the refinement pass.

## Project Requirements

Each requirement carries a type and a change-type against the product layer. This is the first
project, so every change-type is **Introduce** against an empty product. The product requirements
each one mints at close-out are listed inline.

### PT-P1-R1 · Technical · Introduce — Pluggable audio-source abstraction

All audio enters the engine through one protocol — an asynchronous sequence of fixed-format frames —
with interchangeable implementations for fixture playback, a pipe/file descriptor, and a Unix
socket, plus a uniform end-of-stream signal. No engine code reaches a real audio API directly.

*Introduces:* PT-R70, PT-R71, PT-R72, PT-R73, PT-R75, PT-R76
*Acceptance:* the same transcription pipeline runs unchanged over a fixture, a pipe, and a socket
source and terminates cleanly on each.

### PT-P1-R2 · Functional · Introduce — Offline transcription

The engine transcribes a complete audio stream with a resident speech-recognition model and emits a
timestamped, per-utterance Markdown transcript with a stable line format.

*Introduces:* PT-R9, PT-R13
*Acceptance:* transcribing a fixture yields a Markdown transcript matching a committed snapshot,
deterministically across repeated runs.

### PT-P1-R3 · Technical · Introduce — Model acquisition with integrity

Recognition models download from their published host with resumable transfers and are verified
against pinned content hashes before use; a mismatch is rejected and retried.

*Introduces:* PT-R54c, PT-R54d
*Acceptance:* an interrupted download resumes to completion; a corrupted file is detected and
re-fetched.

### PT-P1-R4 · Technical · Introduce — Canonical audio storage

Recorded audio is stored as 16 kHz mono 16-bit PCM WAV — the single canonical on-disk audio format.

*Introduces:* PT-R54e
*Acceptance:* stored WAVs are 16 kHz mono Int16 and are re-readable by the refinement pass.

### PT-P1-R5 · Functional · Introduce — Offline speaker diarization

The system stream is diarized offline into speaker turns with per-speaker voice embeddings; the
microphone stream is never diarized — it is always the local speaker.

*Introduces:* PT-R15a, PT-R17, PT-R29
*Acceptance:* a two-party recording yields distinct speaker turns over the system stream; mic-origin
speech is always attributed to the local speaker.

### PT-P1-R6 · Functional · Introduce — Post-recording refinement pass

On demand, a recording is re-transcribed at refinement quality, diarized globally, merged by
timestamp into an authoritative transcript written atomically, accompanied by a metadata sidecar,
and driven from the command line.

*Introduces:* PT-R20, PT-R21, PT-R24, PT-R25, PT-R26, PT-R38, PT-R39, PT-R48
*Acceptance:* refining a recording produces a final transcript and metadata sidecar; an
interrupted refine leaves no partial transcript behind.

### PT-P1-R7 · Functional · Introduce — Persistent speaker library

A durable store carries speaker identity across recordings: per-speaker centroids updated by a
running mean, reconciliation of a recording's speakers against the store, stable speaker IDs,
concurrent-safe journaling, recoverable deletes, and command-line management.

*Introduces:* PT-R22, PT-R23, PT-R28, PT-R30, PT-R32a, PT-R32b, PT-R49, PT-R83
*Acceptance:* a returning speaker in a second recording is matched to the same stable ID and name.

### PT-P1-R8 · Technical · Introduce — Append-only events log

Every significant operation appends exactly one self-describing JSON record to a daily,
rotation-retained event stream with a common envelope; the stream is a versioned public API and
never carries audio, transcript text, or full paths.

*Introduces:* PT-R78, PT-R79, PT-R80, PT-R81, PT-R82, PT-R84, PT-R85
*Acceptance:* a refinement run emits a causal, schema-valid sequence of events containing no
content.

### PT-P1-R9 · Technical · Introduce — Content-safe operational logging

The system writes daily-rotated, retention-bounded plain-text operational logs that never contain
audio, transcript text, speaker names, or full user paths, mirrored to the unified system log.

*Introduces:* PT-R57, PT-R58, PT-R59, PT-R60, PT-R61
*Acceptance:* a log content-leak test passes; subprocess stderr is captured into the same log.

### PT-P1-R10 · Technical · Introduce — Deterministic, layered tests

The product is covered by independently runnable unit, pipeline, and Python test layers; pipeline
tests are deterministic (seeded, pinned, snapshot-asserted) and include a real IPC integration
test over the source seam.

*Introduces:* PT-R62, PT-R63, PT-R64, PT-R65, PT-R67, PT-R67a
*Acceptance:* the test layers run green independently and reproducibly.

### PT-P1-R11 · Constraint · Introduce — Local-only operation

Audio never leaves the device and the product carries no telemetry or analytics; the only outbound
network access is the first-run model download from its published host.

*Introduces:* PT-R87
*Acceptance:* no code path transmits audio, transcript, or usage data off-device.

### PT-P1-R12 · Constraint · Introduce — Open-source dependencies only

The product depends only on open-source components; no closed-source dependency is embedded.

*Introduces:* PT-R88
*Acceptance:* every shipped dependency has an open-source licence.

### PT-P1-R13 · Constraint · Introduce — Versioned public contracts

The transcript files and the events log are public contracts; a breaking change to either is
accompanied by a major-version bump and a migration note.

*Introduces:* PT-R89
*Acceptance:* a format change without a version bump fails review.
