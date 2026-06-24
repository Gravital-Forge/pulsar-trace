# PT — Architecture

What PulsarTrace is built from: the structural components of the engine, library, and command-line
tool, and the processes they own. The two public output contracts have their own normative
specifications — see `events-log.md` and `transcript-format.md`.

## Components

### PT-C1 · Audio Source Layer

The seam through which all audio enters the engine: the `AudioFrameSource` protocol (an async
sequence of 16 kHz mono Float32, 20 ms frames) and its fixture, pipe, and socket implementations,
with a uniform end-of-stream. Engine code consumes audio only through this layer.

*Interactions:* feeds the Transcription Engine and the Diarization Engine; sources are constructed by
the engine executable from its invocation mode.

*Satisfies:* PT-R70, PT-R71, PT-R72, PT-R73, PT-R75, PT-R76

### PT-C2 · Transcription Engine

Turns audio frames into transcript text using a resident native recognizer (whisper.cpp via the
`CWhisper` C-interop target, GPU-accelerated). Owns the offline whole-stream transcription pass and
the transcript-document assembly, with blank/no-speech filtering. Recognizer access is serialized by
a process-wide lock.

*Interactions:* reads from the Audio Source Layer; loads models via the Model Store; emits the
transcript consumed by the Refinement Pipeline.

*Satisfies:* PT-R9, PT-R13

### PT-C3 · Diarization Engine

Produces speaker turns and per-speaker embeddings for the system stream by running the pyannote
community-1 pipeline as a one-shot Python subprocess with a typed JSON contract; never diarizes the
microphone stream. Owns the transcript-to-turns merge by dominant overlap. The subprocess emits no
telemetry.

*Interactions:* reads system-stream audio; its turns and embeddings flow to the Refinement Pipeline
and the Speaker Library.

*Satisfies:* PT-R15a, PT-R17, PT-R29

### PT-C4 · Refinement Pipeline

The post-recording pass that produces the authoritative transcript: re-transcribe, diarize globally,
merge by timestamp, reconcile speakers, and write the final transcript atomically with its metadata
sidecar. Owns recording-folder input dispatch and the atomic write-with-backup process. Offline
decoding runs per voice-activity region (escaping silence-repetition and preserving cross-turn order)
with a phrase-plus-confidence hallucination gate. An in-process refiner shares this path with the
menubar, and a retroactive rewriter re-renders affected final transcripts after a speaker edit.

*Interactions:* drives the Transcription and Diarization engines and the Speaker Library; writes the
Transcript Output; emits refinement, file, and speaker-rewrite events to the Events Log.

*Satisfies:* PT-R20, PT-R21, PT-R24, PT-R25, PT-R26, PT-R38, PT-R39, PT-R48, PT-R90, PT-R91

### PT-C5 · Speaker Library

A durable SQLite store (WAL mode) of speaker identity — centroids, names, counts, stable
`spk_<ulid>` IDs — with running-mean centroid updates, reconciliation against a recording's
clusters, soft-delete with undo, and corruption auto-restore. Owns the merge/unmerge centroid
arithmetic and speaker delisting; a per-line fallback for speech overlapping no diarized turn labels
the line without becoming a person.

*Interactions:* read and written by the Refinement Pipeline; managed by the CLI and the Menubar
editor; edits drive the retroactive rewriter.

*Satisfies:* PT-R22, PT-R23, PT-R28, PT-R30, PT-R32a, PT-R32b, PT-R49, PT-R83, PT-R105

### PT-C6 · Events Log

The append-only, machine-readable JSON event stream — a public contract. Owns the envelope, the
event registry, daily rotation, retention, and an exclusive advisory lock that serializes appends
across the capture, menubar, and CLI processes. Normative detail in `events-log.md`.

*Interactions:* written by every component that performs a significant operation; read by external
agents and by the CLI.

*Satisfies:* PT-R78, PT-R79, PT-R80, PT-R81, PT-R82, PT-R84, PT-R85, PT-R96

### PT-C7 · Operational Logging

Content-safe operational logging: a dual backend (rotating file plus the unified system log) with a
content-leak scanner and subprocess-stderr capture.

*Interactions:* used by all components; independent of the Events Log.

*Satisfies:* PT-R57, PT-R58, PT-R59, PT-R60, PT-R61

### PT-C8 · IPC Layer

The protocol definitions for inter-process audio and control: a binary frame protocol (with in-band
pause/resume control frames distinguished by length) and a JSON-line control protocol, used across the
engine/capture boundary.

*Interactions:* underlies the socket source and the Capture Daemon's two streams.

*Satisfies:* PT-R67a, PT-R77

### PT-C9 · Command-Line Interface

The `pulsartrace` tool: `refine` (run the refinement pass), `speakers` (manage the library), `record`
(run a full session via the engine orchestrator), `doctor` (environment checks and a tone-based
capture self-test), `events tail` (stream the event log), and `install-cli` (symlink with consent).

*Interactions:* drives the Refinement Pipeline, the Speaker Library, and the record orchestrator;
spawns the Capture Daemon and engine for `record`.

*Satisfies:* PT-R47, PT-R48, PT-R49, PT-R50, PT-R51, PT-R68, PT-R86

### PT-C10 · Model Store

Acquires and verifies recognition models: resumable download, pinned content-hash verification, and
a single product-owned cache root; emits a model-download event.

*Interactions:* used by the Transcription Engine; writes to the Events Log.

*Satisfies:* PT-R54c, PT-R54d

### PT-C11 · Transcript Output

The transcript files PulsarTrace writes — a public contract. Owns the final-transcript marker, the
atomic write/backup discipline, and the metadata sidecar format. Normative detail in
`transcript-format.md`.

*Interactions:* written by the Refinement Pipeline; read by users and external tools.

*Satisfies:* PT-R13, PT-R24, PT-R38, PT-R39, PT-R89

### PT-C12 · Streaming Transcription

The live transcription pass: an anchored window over the system stream with a LocalAgreement-2
committer that emits only utterances two successive decodes agree on, so the live transcript never
revises a word. Decoding is deterministic (zero temperature) and its cadence is tuned to keep live
lag within bound while freeing the recognizer; per-window language detection is restricted to a
configured allow-list. Owns the live commit discipline; its surrounding responsibilities are split
into focused types (live sink, diarization state, gate).

*Interactions:* reads the system source (PT-C1); commits through the Live Markdown Writer; shares the
recognizer (PT-C2).

*Satisfies:* PT-R10, PT-R11, PT-R14, PT-R102

### PT-C13 · Live Diarization

Windowed diarization of the system stream via a long-lived subprocess, stitching provisional speaker
identity across windows by embedding similarity, with read-only speaker-library lookup to surface
known names. Never writes the library.

*Interactions:* reads the system source (PT-C1) and the Speaker Library (PT-C5); labels live
utterances for the Live Markdown Writer.

*Satisfies:* PT-R15, PT-R16, PT-R18, PT-R32

### PT-C14 · Live Markdown Writer

Writes the provisional live transcript — created at session start with its marker and header,
strictly append-only with atomic per-line writes — and drops microphone-echo duplicates. Its contract
is part of the Transcript Output spec (`transcript-format.md`).

*Interactions:* written by Streaming Transcription and Live Diarization; its file is replaced by the
final transcript at refinement.

*Satisfies:* PT-R12, PT-R19, PT-R35, PT-R35a, PT-R36, PT-R37

### PT-C15 · Capture Daemon

The `pulsartrace-capture` process — the only permission-gated component. Captures the microphone
(AVFoundation) and system audio (ScreenCaptureKit), resampling and downmixing to the canonical frame
format at the source, and delivers both over Unix sockets. Owns sleep/wake and device-change recovery
via in-band pause/resume control frames, per-engine frame-watchdog stall detection with backoff
restart, and microphone selection / system-audio toggling.

*Interactions:* feeds the engine's socket sources over the IPC layer (PT-C8); emits
recording-lifecycle and permission events (PT-C6).

*Satisfies:* PT-R1, PT-R2, PT-R3, PT-R4, PT-R5, PT-R6, PT-R7, PT-R8, PT-R74, PT-R77

### PT-C16 · Menubar Application

The `pulsartrace-mac` menubar app and its `PulsarTraceMenuBar` view-model library: status display,
recording control with a passive global hotkey (recorded directly in settings), persisted settings,
the speaker-library editor, and a master–detail main window that lists recordings (scanned from
metadata sidecars, renameable, searchable) beside an in-window transcript detail rendering the
selected — including a live — transcript through one styled renderer. Posts a system notification on
refinement completion or failure, and exposes accessibility labels on its controls.

*Interactions:* drives recording and the in-process refiner (PT-C4); reads the live transcript;
edits the Speaker Library (PT-C5); surfaces the Refinement Job Queue (PT-C17).

*Satisfies:* PT-R31, PT-R40, PT-R41, PT-R42, PT-R43, PT-R44, PT-R45, PT-R103, PT-R104, PT-R106

### PT-C17 · Refinement Job Queue

A single-worker FIFO queue, persisted as JSONL, that runs refinement off the recording path:
per-voice-activity-region checkpointing via a resumable refiner, a pause gate that yields to a
starting recording and resumes from checkpoint, and one recognizer reused per job. The menubar drives
refinement through it; the CLI keeps the direct one-shot path.

*Interactions:* drives the Refinement Pipeline (PT-C4); paused by a recording start; surfaced by the
Menubar Application (PT-C16).

*Satisfies:* PT-R94, PT-R95

### PT-C18 · Recording Durability

Keeps the recording safe under failure: incremental crash-safe WAV writing (header re-patched as it
grows), capture stall detection driving engine rebuilds, and the live run split into a recording-safe
drain (WAV + diarization + a bounded drop-oldest queue, never calling the recognizer) plus a
best-effort, offloaded decode worker with a watchdog. Neither a stall nor a wedged decode loses the
recording.

*Interactions:* wraps the live pass (PT-C12, PT-C14) and the Capture Daemon (PT-C15); offloads decode
to the Out-of-Process Recognizer (PT-C19).

*Satisfies:* PT-R92, PT-R93, PT-R97

### PT-C19 · Out-of-Process Recognizer

Hosts the recognizer in a separate `pulsartrace-whisper` subprocess over a length-prefixed IPC codec,
so a wedged native decode can be force-killed and respawned from the parent without taking down the
engine.

*Interactions:* invoked by the live decode worker and the refiner over the IPC layer (PT-C8); managed
by Recording Durability (PT-C18). It shares the unified `RemoteTranscriberCore` between its live
(`RemoteWindowTranscriber`) and refinement (`RemoteRegionTranscriber`) IPC clients, so host
kill/respawn policy is defined once.

*Satisfies:* PT-R97

### PT-C20 · Security & Privacy Hardening

The on-disk and cross-process privacy posture: content-bearing files are owner-only (0600),
product-owned directories private (0700) with looser pre-existing permissions repaired, internal
socket servers authenticate the peer is the same user, authoritative writes fsync before rename, and
log output redacts home and temporary-directory paths.

*Interactions:* applied by every component that writes files or opens a socket — the Refinement
Pipeline, Transcript Output, Events Log, Speaker Library, Capture Daemon, and IPC layer.

*Satisfies:* PT-R98, PT-R99, PT-R100, PT-R101
