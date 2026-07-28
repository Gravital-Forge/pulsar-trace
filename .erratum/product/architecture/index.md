# PT — Architecture

What PulsarTrace is built from: the structural components of the engine, library, and command-line
tool, and the processes they own. The two public output contracts have their own normative
specifications — see `events-log.md` and `transcript-format.md`.

## Components

### PT-C1 · Audio Source Layer

The seam through which all audio enters the engine: the `AudioFrameSource` protocol (an async
sequence of 16 kHz mono Float32, 20 ms frames) and its fixture, pipe, and socket implementations,
with a uniform end-of-stream. Engine code consumes audio only through this layer.

*Interactions:* feeds the Transcription Engine and the Diarization Engine; sources are constructed
by the engine executable from its invocation mode.

*Satisfies:* PT-R70, PT-R71, PT-R72, PT-R73, PT-R75, PT-R76

### PT-C2 · Transcription Engine

Turns audio frames into transcript text using resident recognizers on the Apple Neural Engine:
Parakeet TDT v3 (via FluidAudio) for the live window pass and WhisperKit (a `large-v3-turbo` default
with a `large-v3` accuracy fallback) for the offline/refine pass, over a fixed model catalog. Owns
the whole-stream and per-region decode assembly with blank/no-speech and hallucination filtering,
the shared transcript option/error types, and an in-process decode that is bounded by a deadline
(per token on refine, per window on live) rather than serialized by a Metal lock.

*Interactions:* reads from the Audio Source Layer; model bundles are acquired via Model Acquisition
(PT-C21); emits the transcript consumed by the Refinement Pipeline and the live pass.

*Satisfies:* PT-R107, PT-R13

### PT-C3 · Diarization Engine

Produces speaker turns and per-speaker embeddings for the system stream by running FluidAudio's
CoreML `speaker-diarization-community-1` pipeline — powerset segmentation, WeSpeaker embeddings, and
AHC/VBx clustering — in-process on the Apple Neural Engine through a resident `DiarizerEngine`;
never diarizes the microphone stream. Owns the transcript-to-turns merge by dominant overlap. One
embedding model serves the offline pass, the live pass, and the Speaker Library, so the embedding
space is unified by construction. There is no Python runtime anywhere in the product.

*Interactions:* reads system-stream audio; model bundles via Model Acquisition (PT-C21); its turns
and embeddings flow to the Refinement Pipeline, Live Diarization, and the Speaker Library.

*Satisfies:* PT-R111, PT-R17, PT-R112

### PT-C4 · Refinement Pipeline

The post-recording pass that produces the authoritative transcript: re-transcribe, diarize globally,
merge by timestamp, reconcile speakers, and write the final transcript atomically with its metadata
sidecar. Owns recording-folder input dispatch and the atomic write-with-backup process. Offline
decoding runs per voice-activity region (escaping silence-repetition and preserving cross-turn
order) with a phrase-plus-confidence hallucination gate. An in-process refiner shares this path with
the menubar, and a retroactive rewriter re-renders affected final transcripts after a speaker edit,
now driven through the shared Speaker Edit Service (PT-C23).

*Interactions:* drives the Transcription and Diarization engines and the Speaker Library; writes the
Transcript Output; emits refinement, file, and speaker-rewrite events to the Events Log.

*Satisfies:* PT-R20, PT-R21, PT-R24, PT-R25, PT-R26, PT-R38, PT-R39, PT-R48, PT-R90, PT-R91

### PT-C5 · Speaker Library

A durable SQLite store (WAL mode) of speaker identity — centroids, names, counts, stable
`spk_<ulid>` IDs — with running-mean centroid updates, reconciliation against a recording's
clusters, soft-delete with undo, and corruption auto-restore. Owns the merge/unmerge centroid
arithmetic and speaker delisting; a per-line fallback for speech overlapping no diarized turn labels
the line without becoming a person. Centroids live in the unified WeSpeaker embedding space with
thresholds calibrated to it; a schema migration archives and resets a database carrying centroids
from a prior, incompatible embedding space.

*Interactions:* read and written by the Refinement Pipeline; managed by the CLI, the Menubar editor,
and the MCP server, all through the shared Speaker Edit Service (PT-C23); edits drive the
retroactive rewriter. The menubar app owns one shared library instance used by both the editor and
the in-process MCP server, so an agent edit and a UI edit are the same writer.

*Satisfies:* PT-R22, PT-R23, PT-R28, PT-R30, PT-R32a, PT-R32b, PT-R49, PT-R83, PT-R105, PT-R113

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
pause/resume control frames distinguished by length) and a JSON-line control protocol, used across
the engine/capture boundary.

*Interactions:* underlies the socket source and the Capture Daemon's two streams.

*Satisfies:* PT-R67a, PT-R77

### PT-C9 · Command-Line Interface

The `pulsartrace` tool: `refine` (run the refinement pass), `speakers` (manage the library — its
mutating subcommands route through the shared Speaker Edit Service, gaining the retroactive
transcript rewrite, with a repeatable `--output-folder` to resolve the roots a non-menubar caller
scans), `record` (run a full session via the engine orchestrator), `doctor` (environment checks and
a tone-based capture self-test), `events tail` (stream the event log), and `install-cli` (symlink
with consent).

*Interactions:* drives the Refinement Pipeline, the Speaker Library through the shared Speaker Edit
Service (PT-C23), and the record orchestrator; spawns the Capture Daemon and engine for `record`.

*Satisfies:* PT-R47, PT-R48, PT-R49, PT-R50, PT-R51, PT-R68, PT-R86

### PT-C10 · Model Store

**Status:** Retired — superseded by Model Acquisition (PT-C21) when models moved to SDK-managed
CoreML bundles identified by a content digest.

Acquired and verified recognition models: resumable download, pinned content-hash verification, and
a single product-owned cache root; emitted a model-download event.

*Interactions:* used by the Transcription Engine; wrote to the Events Log.

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

*Interactions:* reads the system source (PT-C1); commits through the Live Markdown Writer; shares
the resident ANE recognizer (PT-C2), bounding each window decode by a deadline so a wedged window is
skipped rather than stalling the pass.

*Satisfies:* PT-R10, PT-R11, PT-R14, PT-R102

### PT-C13 · Live Diarization

Windowed diarization of the system stream, in-process over the resident `DiarizerEngine` (PT-C3),
stitching provisional speaker identity across windows by embedding similarity, with read-only
speaker-library lookup to surface known names. A single in-flight window is gated so a wedged window
never stalls transcription or the live transcript, and an utterance with no diarized coverage takes
a neutral provisional marker rather than a named speaker. Never writes the library.

*Interactions:* reads the system source (PT-C1), runs the Diarization Engine (PT-C3), and reads the
Speaker Library (PT-C5); labels live utterances for the Live Markdown Writer.

*Satisfies:* PT-R15, PT-R16, PT-R18, PT-R32

### PT-C14 · Live Markdown Writer

Writes the provisional live transcript — created at session start with its marker and header,
strictly append-only with atomic per-line writes — and drops microphone-echo duplicates. Its
contract is part of the Transcript Output spec (`transcript-format.md`).

*Interactions:* written by Streaming Transcription and Live Diarization; its file is replaced by the
final transcript at refinement.

*Satisfies:* PT-R12, PT-R19, PT-R35, PT-R35a, PT-R36, PT-R37

### PT-C15 · Capture Daemon

The `pulsartrace-capture` process — the only permission-gated component. Captures the microphone
(AVFoundation) and system audio (ScreenCaptureKit), resampling and downmixing to the canonical frame
format at the source, and delivers both over Unix sockets. Owns sleep/wake and device-change
recovery via in-band pause/resume control frames, per-engine frame-watchdog stall detection with
backoff restart, and microphone selection / system-audio toggling. A fixture-mode recording
(PT-R127) runs with no capture daemon at all — the engine consumes committed fixture WAVs directly
through the Audio Source Layer (PT-C1).

*Interactions:* feeds the engine's socket sources over the IPC layer (PT-C8); emits
recording-lifecycle and permission events (PT-C6).

*Satisfies:* PT-R1, PT-R2, PT-R3, PT-R4, PT-R5, PT-R6, PT-R7, PT-R8, PT-R74, PT-R77

### PT-C16 · Menubar Application

The `pulsartrace-mac` menubar app and its `PulsarTraceMenuBar` view-model library: status display,
recording control with a passive global hotkey (recorded directly in settings), persisted settings,
the speaker-library editor, and a master–detail main window that lists recordings (scanned from
metadata sidecars, renameable, searchable) beside an in-window transcript detail rendering the
selected — including a live — transcript through one styled renderer. Posts a system notification on
refinement completion or failure. Every driven control carries a stable accessibility identifier
from the `A11yID` registry (PT-R128), and the menubar panel dismisses itself when a navigation row
opens the main window — nothing "clicks outside" under accessibility driving. Honors the
environment-driven isolation overrides (PT-R126) and a fixture-capture record plan (PT-R127) that
runs the full record flow from committed WAVs through an engine-only orchestrator. It owns the
single shared Speaker Library instance, delegates speaker edits to the Speaker Edit Service
(PT-C23), and hosts the opt-in in-process MCP Server (PT-C22) via an `MCPController` — with a
Settings section for the toggle, port, live `/healthz` status, copyable connection snippet, and
manual restart.

*Interactions:* drives recording and the in-process refiner (PT-C4); reads the live transcript;
edits the Speaker Library (PT-C5) through the Speaker Edit Service (PT-C23); surfaces the Refinement
Job Queue (PT-C17); hosts the MCP Server (PT-C22).

*Satisfies:* PT-R31, PT-R40, PT-R41, PT-R42, PT-R43, PT-R44, PT-R45, PT-R103, PT-R104, PT-R106,
PT-R114, PT-R126, PT-R127, PT-R128

### PT-C17 · Refinement Job Queue

A single-worker FIFO queue, persisted as JSONL, that runs refinement off the recording path:
per-voice-activity-region checkpointing via a resumable refiner, a pause gate that yields to a
starting recording by cancelling the in-flight ANE decode at a token boundary and requeuing the job
to resume from checkpoint, and one recognizer reused per job. The menubar drives refinement through
it; the CLI keeps the direct one-shot path.

*Interactions:* drives the Refinement Pipeline (PT-C4); paused by a recording start; surfaced by the
Menubar Application (PT-C16).

*Satisfies:* PT-R94, PT-R95

### PT-C18 · Recording Durability

Keeps the recording safe under failure: incremental crash-safe WAV writing (header re-patched as it
grows), capture stall detection driving engine rebuilds, and the live run split into a
recording-safe drain (WAV + diarization + a bounded drop-oldest queue, never calling the recognizer)
plus a best-effort decode bounded by an in-process deadline. Neither a stall nor a wedged decode
loses the recording; a wedged decode is recovered in-process — the live window is skipped and a
refine job requeues from checkpoint — rather than by force-killing a recognizer process.

*Interactions:* wraps the live pass (PT-C12, PT-C14) and the Capture Daemon (PT-C15); drives the
in-process recognizer (PT-C2) under a deadline.

*Satisfies:* PT-R92, PT-R93, PT-R110

### PT-C19 · Out-of-Process Recognizer

**Status:** Retired — removed when transcription moved to the in-process Apple Neural Engine
backends; its decode-hang isolation is now provided in-process (PT-R110, via PT-C2 / PT-C17 /
PT-C18).

Hosted the recognizer in a separate `pulsartrace-whisper` subprocess over a length-prefixed IPC
codec, so a wedged native decode could be force-killed and respawned from the parent without taking
down the engine. It shared a unified `RemoteTranscriberCore` between its live and refinement IPC
clients.

*Interactions:* was invoked by the live decode worker and the refiner over the IPC layer (PT-C8);
managed by Recording Durability (PT-C18).

*Satisfies:* PT-R97

### PT-C20 · Security & Privacy Hardening

The on-disk and cross-process privacy posture: content-bearing files are owner-only (0600),
product-owned directories private (0700) with looser pre-existing permissions repaired, internal
socket servers authenticate the peer is the same user, authoritative writes fsync before rename, and
log output redacts home and temporary-directory paths.

*Interactions:* applied by every component that writes files or opens a socket — the Refinement
Pipeline, Transcript Output, Events Log, Speaker Library, Capture Daemon, and IPC layer.

*Satisfies:* PT-R98, PT-R99, PT-R100, PT-R101

### PT-C21 · Model Acquisition & Content Digest

Acquires the CoreML model bundles through their managing SDKs (WhisperKit, FluidAudio) into a single
product-owned cache root, and identifies each bundle by a deterministic content digest — a tree hash
of the bundle directory — recorded on the model-download event. There is no PulsarTrace-owned
downloader and no pinned-hash gate; an upstream bundle revision changes the digest rather than
failing. The digest is the model identity downstream — the Speaker Library refuses to match
centroids across a digest change.

*Interactions:* used by the Transcription Engine (PT-C2) and the Diarization Engine (PT-C3); writes
the model-download event to the Events Log (PT-C6). Replaces the retired Model Store (PT-C10).

*Satisfies:* PT-R108, PT-R109

### PT-C22 · MCP Server

The opt-in, loopback-only agent control surface: the `PulsarTraceMCP` library — a tool registry and
JSON-RPC handlers over the official MCP Swift SDK's stateless HTTP transport, behind a hand-rolled
`Network.framework` `NWListener` loopback HTTP/1.1 front end with a bounded request body and idle
timeout — plus the `MCPController` that owns its lifecycle in the menubar process. Disabled by
default; binds `127.0.0.1` on a configurable port (default `8276`); every request carries a
persistent owner-only bearer token validated, with a constant-time compare, ahead of the transport.
Exposes an unauthenticated `/healthz` and rebuilds a failed listener with bounded backoff, surfacing
a persistent bind failure rather than rotating ports. Hosts a 17-tool surface — recording and
speaker queries, the nine thin speaker-management tools (refused during capture), recording
title-set and refine-request, an event query, and a self-describing operations manual — that returns
identity, state, and filesystem paths only, never transcript or audio bytes, and that cannot change
settings, model selection, or capture.

*Interactions:* hosted by the Menubar Application (PT-C16) over the single shared Speaker Library
(PT-C5) that the menubar editor also uses; drives speaker edits through the Speaker Edit Service
(PT-C23); reads the recordings scan, the Speaker Library, and the Events Log (PT-C6); enqueues
refines onto the Refinement Job Queue (PT-C17). The tool-handling core is transport-agnostic, so a
future LAN transport is an isolated addition rather than a rewrite.

*Satisfies:* PT-R115, PT-R116, PT-R117, PT-R118, PT-R119, PT-R120, PT-R121, PT-R122, PT-R124,
PT-R125

### PT-C23 · Speaker Edit Service

The reusable engine actor that orchestrates a speaker edit end to end: mutate the Speaker Library
with its event suppressed, run the retroactive `final.md` rewriter over the affected appearances,
then emit the `speaker_*` cause event before its `final_md_rewritten` effects. The menubar editor,
the MCP server, and the CLI all invoke it, so an edit produces identical file and event effects
regardless of who triggered it; a process-wide non-reentrant lock serializes the whole
mutate→rewrite→emit sequence so concurrent edits cannot lose a transcript rewrite. Owns the shared
speaker-name validation rule, the unchanged-name no-op, and the microphone-speaker delist refusal.

*Interactions:* invoked by the Menubar Application (PT-C16), the MCP Server (PT-C22), and the
Command-Line Interface (PT-C9); mutates the Speaker Library (PT-C5) and drives the Refinement
Pipeline's retroactive rewriter (PT-C4); emits to the Events Log (PT-C6).

*Satisfies:* PT-R123

### PT-C24 · End-to-End Verification Harness

The verification layer over the shipped app. Owns the committed XcodeGen wrapper spec
(`project.yml`) that generates a disposable, gitignored Xcode project compiling the menubar sources
into a testable bundle; the XCUITest suites (`UITests/PulsarTraceUITests` — launch smoke, floor,
record flow, settings persistence, speaker flows) with their seeded-home and artifact-probe helpers;
the run scripts (`scripts/run-ui-tests.sh`, `scripts/start-ui-session.sh` for the dev-desktop
automation-mode ceremony); the hosted-CI workflow (`.github/workflows/ci.yml` — package build plus
hermetic filters, UI floor, a model-cached record-flow lane, and a non-gating runner-capability
probe); the real-audio smoke (`scripts/e2e-audio-smoke.sh`); and the agent verification runbook
(`docs/agent-verification.md`). Tests address the UI exclusively through the `A11yID` identifier
registry, which lives in the `PulsarTraceMenuBar` library so views attach identifiers at definition.
Every tier runs against isolated roots (PT-R134), sharing only the read-only model cache by explicit
opt-in.

*Interactions:* drives the Menubar Application (PT-C16) through its isolation and fixture seams
(PT-R126, PT-R127) and the Audio Source Layer's fixture path (PT-C1); the audio smoke drives the
Command-Line Interface (PT-C9) and the Capture Daemon (PT-C15); the runbook cross-checks through the
Transcript Output (PT-C11), the Events Log (PT-C6), and the MCP Server (PT-C22).

*Satisfies:* PT-R128, PT-R129, PT-R130, PT-R131, PT-R132, PT-R133, PT-R134
