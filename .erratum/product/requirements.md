# PT — Requirements

The active requirements of PulsarTrace: a local-only macOS app that transcribes meetings — capturing
audio, transcribing and diarizing it, refining it into an authoritative transcript, and carrying
speaker identity across recordings — entirely on the user's machine.

## Audio & stream sources

### PT-R70 · Technical — Pluggable audio-source protocol

All audio enters the engine as an asynchronous sequence of fixed-format frames through one protocol;
no engine code reaches a real audio API directly. *Acceptance:* the transcription pipeline runs
unchanged over any conforming source.

### PT-R71 · Technical — Fixture playback source

A source plays a WAV file at real-time pace, with a fast mode for tests.

### PT-R72 · Technical — Pipe source

A source reads PCM frames from a file descriptor (stdin or an arbitrary fd).

### PT-R73 · Technical — Socket source

A source reads PCM frames from a Unix domain socket.

### PT-R75 · Technical — Uniform end-of-stream

Every source emits one clean end-of-stream signal, handled identically downstream.

### PT-R76 · Technical — Canonical frame format

Frames are 16 kHz mono Float32, 20 ms (320 samples).

## Transcription

### PT-R107 · Functional — Resident ANE transcription

The engine transcribes a complete audio stream with recognition models held resident on the Apple
Neural Engine — a fixed live model for the streaming pass and a refinement model chosen from a small
fixed catalog for the post pass — without a per-call model load. *Acceptance:* a fixture transcribes
through the resident ANE backends with no native GPU recognizer; the live model is fixed and the
refine model is a settings/flag choice.

### PT-R13 · Functional — Transcript line format

A transcript is a header followed by per-utterance lines `**[HH:MM:SS] Speaker:** text`, timestamped
in seconds since recording start.

### PT-R108 · Technical — SDK-managed model acquisition

Recognition and diarization models are bundles acquired by their managing SDKs into a single
product-owned cache root; the product owns no separate model downloader. *Acceptance:* models
download via the SDKs into the product cache root on first use.

### PT-R109 · Technical — Content-digest model integrity

A model bundle's identity is a deterministic content digest — a tree hash of the bundle directory —
recorded when the bundle is acquired, rather than a verification against a pinned hash; an upstream
revision changes the digest, not a hard failure. *Acceptance:* the model-download event carries the
bundle's content digest, and downstream identity checks key on it.

### PT-R54e · Technical — Canonical audio storage

Stored audio is 16 kHz mono 16-bit PCM WAV.

## Diarization

### PT-R111 · Functional — In-process offline diarization of the system stream

The system stream is diarized offline, in-process on the Apple Neural Engine, into speaker turns.
*Acceptance:* a refine diarizes the system stream in-process with no diarization subprocess.

### PT-R17 · Functional — Microphone is never diarized

Microphone-origin speech is always attributed to the local speaker, never sent to diarization.

### PT-R112 · Technical — Unified speaker-embedding space

Per-speaker voice embeddings are produced by one diarization model shared across the live pass, the
offline pass, and the speaker library — a single embedding space by construction — with match and
stitch thresholds calibrated to that space. *Acceptance:* live, offline, and library embeddings come
from one model; the thresholds are pinned by a calibration test.

### PT-R113 · Technical — Diarization schema migration

A change of diarization model that moves the embedding space migrates persisted data one way: the
speaker library archives and resets a database carrying centroids from the prior space, and the
metadata sidecar records the diarization model's identity and revision. *Acceptance:* opening a
library from an incompatible prior space archives and resets it; a fresh refine records the
diarization model id and revision in the metadata sidecar.

## Refinement

### PT-R20 · Functional — Refinement re-transcription

On refinement, a recording is re-transcribed at refinement quality.

### PT-R21 · Functional — Global diarization for clustering

Refinement diarizes the system stream globally to cluster speakers across the whole recording.

### PT-R24 · Functional — Atomic authoritative transcript

The final transcript is written atomically; the prior input transcript is preserved as a backup.

### PT-R25 · Technical — Refinement performance

Refinement completes within roughly one times the recording's wall-clock length on target hardware.

### PT-R26 · Functional — Non-blocking refinement with progress

Refinement reports progress and runs without blocking interaction.

### PT-R38 · Technical — Final-transcript marker

The authoritative transcript carries a completion marker distinguishing it from provisional output.

### PT-R39 · Technical — Metadata sidecar

A sidecar records the recording's speakers, durations, model identities, and a schema version.

### PT-R48 · Functional — `refine` command

A command re-runs the refinement pass over an existing recording, including re-refining an
already-refined recording with the current models and speaker library.

### PT-R90 · Functional — Retroactive transcript rewrite on speaker edit

A speaker rename, merge, split, or unmerge retroactively rewrites the affected final transcripts and
their metadata, atomically, emitting the paired rewrite event; the live transcript is never
rewritten.

### PT-R91 · Functional — Robust offline decoding

Offline refinement resists silence-induced repetition, preserves cross-turn ordering by decoding per
speech region, and drops a silence-hallucination phrase only when an objective confidence signal
agrees.

## Speaker library

### PT-R22 · Functional — Reconcile speakers against the library

A recording's post-pass speaker clusters are matched against the library by centroid similarity.

### PT-R23 · Functional — Update the library at the post-pass

The post-pass adds new speakers and refines existing centroids in the library.

### PT-R28 · Technical — Durable speaker store

The library persists per speaker: id, name, centroid, appearance count, last-seen, sample path.

### PT-R30 · Technical — Running-mean centroids

A speaker's centroid updates by a count-weighted running mean.

### PT-R32a · Technical — Concurrent-safe journaling

The store uses write-ahead journaling so a reader and a writer can run concurrently.

### PT-R32b · Functional — Recoverable deletes

Destructive operations are soft-deleted and recoverable within an undo window.

### PT-R49 · Functional — `speakers` command

A command lists, renames, merges, and deletes speakers in the library.

### PT-R83 · Technical — Stable speaker IDs

Each speaker has a stable internal ID; a rename changes the name, never the ID.

### PT-R105 · Functional — Speaker delisting and cleaner surfacing

A speaker can be delisted so it is no longer treated as a person, and a per-line fallback for speech
overlapping no diarized turn labels the line without earning a speaker pill or a metadata entry.

## Events log

### PT-R78 · Technical — Append-only event stream

Significant operations append to a daily JSONL event file.

### PT-R79 · Technical — Event-log rotation and retention

The event log rotates daily and old files are pruned on a retention window.

### PT-R80 · Technical — Common event envelope

Every event carries a common envelope: timestamp, type, unique id, and version.

### PT-R81 · Technical — Documented, versioned event types

Event types are documented and each carries its own evolving version.

### PT-R82 · Functional — One event per significant operation

Each significant operation emits exactly one event.

### PT-R84 · Constraint — Event log carries no content

The event log never contains audio, transcript text, or full paths; ids, names, and hashes are
permitted.

### PT-R85 · Constraint — Event log is a public contract

The event log is a public API surface; format changes follow versioning.

## Operational logging

### PT-R57 · Technical — Rotated operational logs

Plain-text operational logs rotate daily with bounded retention.

### PT-R58 · Technical — Default log level

The default level is notice; more verbose levels are off by default and toggleable.

### PT-R59 · Constraint — Content-safe logs

Operational logs never contain audio, transcript text, speaker names, or full user paths.

### PT-R60 · Technical — Subprocess stderr capture

Subprocess stderr is captured into the operational log under a tag.

### PT-R61 · Technical — System-log mirror

Operational logs are mirrored to the unified system log.

## Testing

### PT-R62 · Technical — Independent test layers

Unit, pipeline, and capture test targets run independently.

### PT-R63 · Technical — Stream-source seam coverage

Tests exercise the source seam across its implementations.

### PT-R64 · Technical — Deterministic pipeline tests

Pipeline tests are deterministic via seeded RNG, fixed decode settings, and pinned inputs.

### PT-R65 · Technical — Snapshot-tested artifacts

Generated text artifacts are snapshot-tested.

### PT-R67a · Technical — IPC integration test

A real Unix-socket frame feed is asserted against the in-process result.

### PT-R66 · Technical — Loopback capture test target

The capture test target exercises real capture against a loopback audio device, and skips when it is
absent.

### PT-R69 · Technical — Release smoke-test checklist

A manual release smoke-test checklist is maintained for the hardware-dependent paths. (The checklist
document is operational and lives outside this directory.)

## Live transcription

### PT-R10 · Functional — Bounded live lag

The live transcript stays within a few seconds of real time at the median.

### PT-R11 · Technical — No mid-word chunk artifacts

Live transcription uses overlap windowing and a two-pass agreement committer so word boundaries are
never cut mid-stream.

### PT-R12 · Technical — Atomic live append

The live transcript is appended atomically, with no torn writes or partial UTF-8.

### PT-R14 · Functional — Live speaker labels

Live labels mark the microphone speaker as the local speaker and system speakers as a generic or
named other party.

### PT-R19 · Functional — Microphone-echo dedup

A system-side duplicate of microphone speech is dropped by text similarity within a small time
window.

### PT-R35 · Functional — Human- and tool-readable live transcript

The live transcript is plain Markdown, readable by a person and by an automated tool.

### PT-R35a · Technical — Live transcript created at session start

The live transcript is created at session start with its provisional marker and a header, before the
first utterance.

### PT-R36 · Constraint — Append-only live transcript

The live transcript is strictly append-only during capture; it grows monotonically and is never
rewritten in place. Any renaming is deferred to the refinement pass.

### PT-R37 · Technical — Live (provisional) marker

The live transcript carries a marker identifying it as provisional output, and marks a provisional
speaker with a compact `?` suffix emitted at the engine source.

### PT-R102 · Functional — Live language allow-list

Per-window live language detection is restricted to a user-configured allow-list rather than ranging
over all languages.

## Live diarization

### PT-R15 · Functional — Live diarization of the system stream

The live pass diarizes the system stream over a sliding window.

### PT-R16 · Functional — Provisional live speaker labels

Live speaker labels are marked provisional.

### PT-R18 · Functional — Live library lookup

During the live pass, a system speaker whose centroid matches the library shows the known name,
still marked provisional.

### PT-R32 · Constraint — Library read-only during the live pass

The speaker library is read-only during the live pass; only the post-pass writes it.

## Capture

### PT-R1 · Functional — Microphone capture

The capture path records the default microphone, downmixed and resampled to the canonical frame
format.

### PT-R2 · Functional — System-audio capture

The capture path records system audio, downmixed and resampled to the canonical frame format.

### PT-R3 · Technical — Capture delivers over a socket

The capture daemon delivers both streams over Unix sockets in the canonical frame format.

### PT-R4 · Constraint — Capture is the sole permissioned process

Only the capture daemon requires OS microphone and screen-recording permissions.

### PT-R5 · Functional — Microphone selection

A non-default microphone can be selected, and the selection persists.

### PT-R6 · Functional — System-audio toggle

System-audio capture can be disabled for a microphone-only recording.

### PT-R7 · Functional — Survive sleep

A recording survives system or display sleep via a pause/resume annotation.

### PT-R8 · Functional — Survive device change

A recording survives an audio-device change mid-session, annotated in the transcript.

### PT-R74 · Technical — Device source conforms to the source protocol

Device capture is exposed through the same audio-source protocol as every other source.

### PT-R77 · Technical — Pausable sources

Audio sources can be paused and resumed for sleep/wake handling.

## Real-time orchestration & CLI

### PT-R47 · Functional — `record` command

A `record` command runs a full session — capture plus live engine, then refine — for a duration or
until interrupted.

### PT-R50 · Functional — `doctor` command

A `doctor` command validates dependencies, permissions, and model presence with an actionable
report.

### PT-R68 · Functional — Capture self-test

`doctor --capture-test` plays a tone and verifies it back through the real capture path.

### PT-R86 · Functional — `events tail` command

A command streams today's events with an optional, validated type filter.

### PT-R51 · Functional — `install-cli` command

A command symlinks the CLI into the user's path with explicit consent, and uninstalls.

## Menubar application

### PT-R40 · Functional — Menubar status

A menubar item shows idle / recording / refining status at a glance.

### PT-R41 · Functional — Menubar recording control

Recording can be started and stopped from the menubar, including a configurable global hotkey.

### PT-R42 · Functional — Persisted settings

Microphone, models, output folder, hotkey, and system-audio toggle are configurable and persisted.

### PT-R31 · Functional — Speaker-library editor

A library editor lists speakers and supports name, play, merge, split, and delete.

### PT-R43 · Functional — Speaker editor in the menubar

The menubar surfaces the speaker-library editor.

### PT-R44 · Functional — Recordings list

The menubar lists recordings by scanning their metadata sidecars, with re-refine and reveal, without
a separate index database.

### PT-R45 · Functional — Live preview

The menubar offers a read-only, real-time preview of the live transcript.

### PT-R104 · Functional — Refinement notifications

A system notification is delivered when a refinement completes or fails.

### PT-R106 · Functional — In-window recordings and transcript viewing

The main window presents recordings master–detail and renders the selected — including a live —
transcript in-window, with rename and find-in-transcript.

### PT-R114 · Functional — First-launch onboarding tour

After first launch, the menubar app offers a short onboarding tour that orients a new user to
recording, the transcript view, and the speaker library; it does not recur once dismissed or
completed.

## Robustness & resilience

### PT-R92 · Functional — Crash-safe incremental recording

Audio is written to disk incrementally so an abnormal end loses at most about one second, and the
on-disk file is always a valid, refine-able recording.

### PT-R93 · Functional — Capture stall recovery

A silently stalled capture stream is detected and its engine rebuilt automatically, surfaced as a
pause/resume, without ending the recording.

### PT-R94 · Functional — Non-blocking queued refinement

Refinement runs through a single-worker queue whose state persists across restarts, so a finished
recording never blocks the next.

### PT-R95 · Functional — Refinement yields to recording

Starting a recording pauses an in-flight refine, which resumes from its on-disk checkpoint
afterward.

### PT-R96 · Technical — Cross-process event-log integrity

Concurrent appends to the shared event log are serialized so records never interleave.

### PT-R110 · Functional — In-process decode-hang recovery

A stuck transcription decode cannot stall or lose the recording, the live transcript, or the audio
file, and is recovered in-process: a wedged refinement decode is cancelled at a token boundary and
resumes from its checkpoint, and a wedged live window is bounded by a deadline and skipped,
recovered by the post pass. *Acceptance:* a hung refine decode resumes from checkpoint after
cancellation; a hung live window is skipped without stalling the recording.

## Security, privacy & accessibility

### PT-R98 · Constraint — Owner-only content files

Every content-bearing file — transcripts, audio, metadata, the event log, the speaker library and
its journal and backup, and internal lock files — is owner-only on disk.

### PT-R99 · Constraint — Private owned directories

Product-owned directories are private, with looser pre-existing permissions repaired; user-chosen
output folders are left as they are.

### PT-R100 · Constraint — Socket peer authentication

Internal Unix-socket servers verify the connecting peer is the same user and reject anyone else.

### PT-R101 · Technical — Durable atomic writes

Authoritative outputs are flushed to disk before the atomic rename, so a crash cannot leave a
truncated file.

### PT-R103 · Constraint — Accessibility labels

Interactive controls carry accessibility labels.

## Product constraints

### PT-R87 · Constraint — Local-only operation

Audio never leaves the device and the product carries no telemetry; the only outbound network access
is the first-run model download from its published host.

### PT-R88 · Constraint — Open-source dependencies only

The product embeds no closed-source dependency.

### PT-R89 · Constraint — Versioned public contracts

The transcript files and the event log are public contracts; a breaking change to either bumps the
major version and ships a migration note.
