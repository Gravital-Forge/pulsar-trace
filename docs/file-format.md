# PulsarTrace transcript file format

This document is the contract for the `live.md` and `final.md` transcript files
PulsarTrace writes per recording. External tools — your AI agent, scripts,
integrations — depend on this format. It is a **public API surface**: breaking
changes require a major version bump and a migration note (PRD §17).

> Status: Epic 1 establishes this spec. Epics 2, 4 and 6 implement the
> generators and extend the detail here. The format below is the target shape;
> any field not yet emitted is marked accordingly.

## Overview

Each recording lives in its own folder under the output directory:

```
2026-04-30-team-standup/
  audio-mic.wav        ← 16kHz mono Int16 PCM (canonical storage format)
  audio-system.wav     ← 16kHz mono Int16 PCM
  live.md              ← provisional transcript, written during the call
  final.md             ← refined transcript, replaces live.md after refinement
  metadata.json        ← sidecar (Epic 4)
```

There are two transcript files, reflecting the product's two-pass model:

- **`live.md`** — written during the recording, append-only. Provisional
  labels. Useful for an AI agent tailing the file mid-call.
- **`final.md`** — written by the offline refinement pass. The source of
  truth. Atomically replaces `live.md` when refinement completes.

## Line format

UTF-8, line-oriented, so consumers can `tail -f` the file.

A file begins with a marker comment and a heading:

```
<!-- pulsartrace:final -->
## Transcript — 2026-04-30 14:30

**[00:00:05] You:** So the main issue is the authentication flow breaks on mobile.

**[00:00:12] Sarah:** Right, I think the redirect URI isn't being handled correctly by the webview.
```

- **Marker comment** — `<!-- pulsartrace:live -->` in `live.md`,
  `<!-- pulsartrace:final -->` in `final.md`. Always the first line. A consumer
  uses it to tell the two file kinds apart.
- **Heading** — `## Transcript — YYYY-MM-DD HH:MM` (R13). The local wall-clock
  at which **recording started**, captured once at session start and never
  recomputed. Epic 4 also stores it in `metadata.json`.
- **Utterance line** — `**[HH:MM:SS] <speaker>:** <text>`
  - `[HH:MM:SS]` — **seconds since recording start** (R13), not wall-clock:
    `00:00:00` at the start of the recording, growing to end-of-recording. The
    hours field simply grows for long recordings (e.g. `04:12:33`); there is no
    wraparound. An elapsed offset rather than wall-clock sidesteps DST and
    timezone-shift edge cases mid-recording.
  - `<speaker>` — `You` for the mic stream; a speaker name or `Unknown #N` for
    system-audio speakers. **Epic 2 (offline transcription) has no diarization
    yet**: it emits a single placeholder label `Speaker` on every line. Epic 3
    replaces it with diarized labels.
  - `(provisional)` — present in `live.md` only, on speakers whose identity is
    not yet confirmed. Removed in `final.md`.

## Invariants

These are enforced by the engine and must not be violated by any consumer's
assumptions:

1. **`live.md` is strictly append-only.** Once a line is written it is never
   edited, reordered, or removed. A speaker rename mid-call applies only to the
   next refinement pass — never to `live.md`.
2. **`live.md` is created at session start** (before the first utterance) so an
   agent tailing the file has a signal immediately. It carries the marker and
   heading from the outset.
3. **`final.md` atomically replaces `live.md`.** The refinement pass writes
   `final.md` via write-then-rename; `live.md` is preserved as `.live.md.bak`.
4. **The mic stream is always `You`** and is never diarized.

## Versioning

The format is SemVer-stable. Adding a new optional line kind or an optional
annotation is a minor change. Removing or repurposing the marker comment, the
heading shape, or the utterance-line grammar is a breaking change requiring a
major version bump and a migration note.
