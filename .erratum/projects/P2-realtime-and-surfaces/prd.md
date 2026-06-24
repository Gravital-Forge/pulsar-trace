# PT-P2 · Real-Time & Surfaces — Project PRD

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Scope

This project turns the offline core into a live, capturing, interactive product. It adds streaming
transcription and live diarization that grow a provisional transcript in real time; real
audio-device capture through a dedicated permissioned daemon; the full operator command-line
surface; and a menubar application that makes the whole flow reachable without a terminal. It also
pays down the correctness debt the first real recordings surfaced in the offline pass.

It builds entirely on the abstractions from PT-P1: live and device sources conform to the same audio
protocol, the live transcript obeys the transcript contract, and capture rides the IPC layer. The
recognition and diarization engines themselves are unchanged in kind (still whisper.cpp and
pyannote) — this project adds real-time modes and surfaces around them, and refines their output
quality, rather than replacing them.

## Project Requirements

All change-types are **Introduce** except where noted; the product layer to date holds only PT-P1's
requirements.

### PT-P2-R1 · Functional · Introduce — Live streaming transcription

A live pass transcribes the system stream as it arrives, committing only stable text to a strictly
append-only live transcript created at session start, bounded in lag, with no word ever revised.

*Introduces:* PT-R10, PT-R11, PT-R12, PT-R14, PT-R35, PT-R35a, PT-R36, PT-R37 *Acceptance:* a
real-time-paced fixture grows the live transcript monotonically with bounded lag.

### PT-P2-R2 · Functional · Introduce — Live speaker diarization

The live pass diarizes the system stream over a sliding window, labels speakers provisionally,
stitching identity across windows, and reads (never writes) the speaker library to show known names.

*Introduces:* PT-R15, PT-R16, PT-R18, PT-R32 *Acceptance:* live speakers carry provisional labels; a
known speaker shows their name, still marked provisional; the library is never written during the
live pass.

### PT-P2-R3 · Functional · Introduce — Microphone-echo dedup

System-side duplicates of microphone speech are dropped from the live transcript by text similarity
within a small time window.

*Introduces:* PT-R19 *Acceptance:* speech captured on both mic and system appears once.

### PT-P2-R4 · Functional · Introduce — Real device capture

A capture path records the default (or chosen) microphone and the system audio, resampled and
downmixed to the canonical frame format at the source boundary, and delivers both over sockets;
system audio is optional.

*Introduces:* PT-R1, PT-R2, PT-R3, PT-R5, PT-R6, PT-R74 *Acceptance:* a real two-stream capture
feeds the engine and produces a live transcript.

### PT-P2-R5 · Technical · Introduce — Capture is the sole permissioned process

Only the capture daemon holds OS audio/screen-recording permissions; no other process is permission-
gated.

*Introduces:* PT-R4 *Acceptance:* permission checks live solely in the capture daemon.

### PT-P2-R6 · Functional · Introduce — Recording survives interruptions

A recording survives system/display sleep and an audio-device change mid-session, annotating the gap
and resuming, via pausable/resumable sources.

*Introduces:* PT-R7, PT-R8, PT-R77 *Acceptance:* sleeping and changing devices mid-recording
annotates a gap and resumes.

### PT-P2-R7 · Functional · Introduce — `record` orchestration

A `record` command runs a full session end-to-end — spawning capture and the live engine, then
refining — for a duration or until interrupted.

*Introduces:* PT-R47 *Acceptance:* `record` produces a recording folder with a final transcript.

### PT-P2-R8 · Functional · Introduce — Environment doctor & self-test

A `doctor` command validates dependencies, permissions, and model presence, including an end-to-end
audio self-test; the capture test target runs against a loopback device when present.

*Introduces:* PT-R50, PT-R68, PT-R66 *Acceptance:* `doctor` reports actionable status and exits
non-zero on any hard failure.

### PT-P2-R9 · Functional · Introduce — Event tail & CLI install

A command tails today's events with an optional type filter; an installer symlinks the CLI with
explicit consent.

*Introduces:* PT-R86, PT-R51 *Acceptance:* `events tail` streams events; `install-cli` symlinks and
uninstalls.

### PT-P2-R10 · Functional · Introduce — Menubar status & control

A menubar app shows recording/refining status, starts and stops recording (including a configurable
global hotkey), and persists settings.

*Introduces:* PT-R40, PT-R41, PT-R42 *Acceptance:* recording can be started, observed, and stopped
entirely from the menubar.

### PT-P2-R11 · Functional · Introduce — Menubar library editor & recordings list

The menubar exposes a speaker-library editor (list / rename / merge / split / delete), a recordings
list scanned from metadata sidecars with re-refine, and a read-only live-transcript preview.

*Introduces:* PT-R31, PT-R43, PT-R44, PT-R45 *Acceptance:* speakers can be edited and recordings
browsed and re-refined from the window.

### PT-P2-R12 · Functional · Introduce — Retroactive transcript rewrite on speaker edit

A speaker rename / merge / split / unmerge retroactively rewrites the affected final transcripts and
updates their metadata, atomically, emitting the paired rewrite event; the live transcript is never
touched.

*Introduces:* PT-R90 *Acceptance:* renaming a speaker rewrites every affected final transcript and
emits the paired event.

### PT-P2-R13 · Functional · Introduce — Robust offline decoding

The offline refinement pass resists silence-induced repetition loops, preserves cross-turn ordering
by decoding per speech region, and drops only objectively-confirmed silence hallucinations.

*Introduces:* PT-R91 *Acceptance:* a recording with long silences and stock-phrase hallucinations
yields a correctly ordered transcript with no spurious lines.

### PT-P2-R14 · Technical · Introduce — Release smoke-test checklist

A manual release smoke-test checklist is maintained for the hardware-dependent paths.

*Introduces:* PT-R69 *Acceptance:* the checklist exists and covers capture, record, and doctor
self-test. (The checklist document itself is operational and lives outside this directory.)
