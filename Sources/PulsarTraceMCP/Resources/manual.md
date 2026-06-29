# PulsarTrace operations manual

PulsarTrace is a local meeting-transcription app. It records a meeting, transcribes it, attributes
each utterance to a speaker, and maintains a speaker library so the same person is recognized across
meetings. This surface lets you inspect what PulsarTrace holds and manage speaker identity and
recording titles. Everything is local to this machine.

## Data model

- **Recording** — one captured meeting, identified by a stable `rec_…` id. It has a start time, a
  duration, a language, a refinement state, the speakers present, and filesystem paths to its
  transcripts and audio. A recording is *live* (only a provisional `live.md` exists) until a refine
  pass produces the final `final.md`.
- **Transcript files** — `final.md` (the refined transcript) and `live.md` (the provisional one).
  Each utterance line is `**[HH:MM:SS] <speaker>:** text`. These are plain files on disk; read them
  from the paths the query tools return. This surface never returns transcript or audio bytes.
- **Speaker** — an identity in the library, identified by a stable `spk_…` id, with a display name,
  an appearance count, and the recordings it appears in. The microphone speaker is named `You`.
- **Event** — an append-only record of what happened (a rename, a merge, a refine, …). Query recent
  events to confirm the effect of an operation.

## Reading

- `list_recordings` — recordings with metadata and paths; filter by `since` / `until` (start time),
  `status` (`live` / `refined` / `all`), and `limit`.
- `get_recording_meta` — one recording's metadata and paths by id.
- `list_speakers` — the live speakers (excludes deleted and delisted).
- `get_speaker` — one speaker with the recordings it appears in.
- `recent_events` — recent events, newest first; filter by `since` and `type`.

## Managing speakers

Each operation has an inverse, so any edit can be reversed. A speaker edit rewrites the speaker's
label across every past `final.md` and records paired events; `live.md` is never rewritten. Speaker
edits are refused while a recording is in progress — the library is read-only during capture.

- `rename_speaker` — change a speaker's name.
- `merge_speakers` / `unmerge_speakers` — combine two speakers into one, or undo it.
- `split_speaker` / `unsplit_speaker` — split some of a speaker's recordings out under a new name, or
  undo it.
- `delist_speaker` / `undelist_speaker` — stop recognizing a speaker (its label is dropped from past
  transcripts; solo lines become `Unrecognized`), or resume. `You` cannot be delisted.
- `delete_speaker` / `undelete_speaker` — soft-delete a speaker (recoverable for 30 days; no
  transcript change), or restore it.

## Managing recordings

- `rename_recording` — set a recording's title; a blank title restores the date-based default.
- `request_refine` — enqueue a (re-)refinement; it runs in the background and returns immediately.
  Watch `recent_events` for `refinement_started` / `final_md_rewritten` / `refinement_completed`.

## What this surface does not do

It does not change settings or model selection, does not start or stop capture, and does not transit
transcript or audio content — read content from the paths the query tools return.
