# PulsarTrace transcript file format

This document is the contract for the `live.md` and `final.md` transcript files
PulsarTrace writes per recording. External tools — your AI agent, scripts,
integrations — depend on this format. It is a **public API surface**: breaking
changes require a major version bump and a migration note (PRD §17).

> Status: Epic 1 establishes this spec. Epics 2 and 4 implement the offline
> generators (`final.md` + `metadata.json`); Epic 5 replaces positional
> `Speaker_N` labels with persistent speaker-library names and adds
> `metadata.json`'s `speaker_id` field; Epic 6 adds the `live.md`
> generator. The format below is the target shape; any field not yet emitted
> is marked accordingly.

## Overview

Each recording lives in its own folder under the output directory:

```
2026-04-30-team-standup/
  audio-mic.wav        ← 16kHz mono Int16 PCM (canonical storage format)
  audio-system.wav     ← 16kHz mono Int16 PCM
  live.md              ← provisional transcript, written during the call
  final.md             ← refined transcript, replaces live.md after refinement
  metadata.json        ← machine-readable sidecar (Epic 4)
```

### Input shapes for `pulsartrace refine` (Epic 4)

`pulsartrace refine PATH` accepts two input shapes (see DECISIONS.md D13):

- **A recording folder** already in the layout above. `refine` transcribes
  `audio-system.wav` (diarized) and, if present, `audio-mic.wav` (the `You`
  stream, never diarized — R17), merges them by timestamp, and writes
  `final.md` + `metadata.json` back into the folder.
- **A bare WAV file** (`meeting.wav`). `refine` treats it as a single-stream
  recording, creates a sibling output folder named for the WAV's stem
  (`meeting/`), and writes `final.md` + `metadata.json` there. The original
  WAV is left untouched. A bare WAV has no separate mic stream, so all its
  speakers are diarized and library-reconciled — there is no `You` label.

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
  - `<speaker>` — `You` for the mic stream; a persistent speaker name for
    system-audio speakers. As of **Epic 5 (speaker library)** every
    system-stream speaker in `final.md` carries its **library name**: a
    user-assigned name (`Steve`) for a recognised returning speaker, or an
    `Unknown #N` placeholder for a speaker the library has not been given a
    name for yet. The refine pass diarizes the system stream with pyannote,
    then reconciles each cluster against the persistent speaker library by
    centroid cosine similarity — a returning voice is auto-labelled with the
    name it was given before, and its stable `spk_<ulid>` id is recorded in
    `metadata.json`. When an utterance is talked over by two speakers, both
    names are surfaced joined with `+` (e.g. `Steve+Unknown #1`); an utterance
    that overlaps no diarized span keeps the fallback label `Speaker_?`.
    - *Historical note:* Epic 2 emitted a single placeholder label `Speaker`;
      Epic 3 replaced it with diarized `Speaker_0`, `Speaker_1`, … labels;
      Epic 5 replaced those positional labels with persistent library names.
      A `final.md` written before Epic 5 (or one refined with the speaker
      library unavailable) still carries `Speaker_N` labels.
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

## `metadata.json` sidecar (Epic 4, R39)

Alongside `final.md`, a refine pass writes `metadata.json` — the machine-readable
summary of the refined recording. An AI agent or script reads it instead of
parsing `final.md` prose. It is a public API surface; it is written atomically
(write-then-rename) like `final.md`.

```json
{
  "schema_version": 1,
  "recording_id": "rec_two-speakers-alternating",
  "recording_start": "2026-05-16T03:26:49Z",
  "refined_at": "2026-05-16T03:26:49Z",
  "duration_seconds": 24,
  "language": "en",
  "source_basename": "two-speakers-alternating.wav",
  "speakers": [
    { "label": "Steve", "is_microphone": false, "speaker_id": "spk_01HW2K…" },
    { "label": "Unknown #1", "is_microphone": false, "speaker_id": "spk_01HW2L…" }
  ],
  "whisper_model": {
    "name": "base",
    "sha256": "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
  },
  "pyannote_model": {
    "id": "pyannote/speaker-diarization-community-1",
    "revision": "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee",
    "library_version": "4.0.4"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `schema_version` | integer | Sidecar schema version. Starts at 1; bumped on a breaking change. |
| `recording_id` | string | `rec_<short>`, derived from the recording folder / WAV name. Stable across re-refines. |
| `recording_start` | string | Wall-clock recording start, ISO-8601 UTC. Mirrors the `final.md` heading. |
| `refined_at` | string | Wall-clock start of the refine pass that produced this file, ISO-8601 UTC. |
| `duration_seconds` | number | Audio duration (the longer of the streams). |
| `language` | string | Transcription language whisper detected/used (ISO-639-1). |
| `source_basename` | string | Basename of the user-supplied `refine` input — never a full path. |
| `speakers` | array | One entry per distinct speaker in `final.md`. |
| `speakers[].label` | string | Transcript-facing label — the persistent library name (`Steve`, `Unknown #1`) for a system speaker; `You` for the mic stream. (Pre-Epic-5 files carry `Speaker_N`.) |
| `speakers[].is_microphone` | boolean | `true` for the `You` (mic) speaker — never diarized (R17). |
| `speakers[].speaker_id` | string\|null | Stable speaker-library id (`spk_<ulid>`, R83) for a reconciled system speaker. `null` for `You`, and for a speaker not reconciled (diarization skipped, or the library was unavailable). An agent keys off this id for stable identity across renames. |
| `whisper_model.name` | string | Whisper model name (`base`, `large-v3`). |
| `whisper_model.sha256` | string | Pinned SHA-256 of the ggml model file (its version identity). |
| `pyannote_model` | object\|null | pyannote model identity. `null` when diarization was skipped (e.g. no speech detected). |
| `pyannote_model.id` | string | Model id, e.g. `pyannote/speaker-diarization-community-1`. |
| `pyannote_model.revision` | string | Hugging Face hub commit SHA of the model checkpoint. |
| `pyannote_model.library_version` | string | pyannote.audio library version. |

When a recording has no usable speech, `final.md` still carries the
`<!-- pulsartrace:final -->` marker and a single explanatory note line
(`_(no speech detected in this recording)_`); `metadata.json` is still written
with an empty `speakers` array and `pyannote_model: null`.

## Versioning

The format is SemVer-stable. Adding a new optional line kind, an optional
annotation, or an optional `metadata.json` field is a minor change. Removing or
repurposing the marker comment, the heading shape, the utterance-line grammar,
or a `metadata.json` field is a breaking change requiring a major version bump
and a migration note.
