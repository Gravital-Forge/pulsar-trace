# PulsarTrace events log schema

The events log is a system-wide, append-only, machine-readable record of every
significant operation in PulsarTrace. It is a **public API surface** alongside
`live.md` and `final.md` (PRD §8.13, R85): LLM agents and external tools consume
it to understand "what's happened in PulsarTrace recently."

> Status: Epic 1 establishes the envelope contract, the rotation/retention
> behavior, and the `app_started` / `app_stopped` system events. Epic 2 adds
> `model_downloaded`. Later epics append their event types to the catalogue
> below as they implement emission.

## File layout

```
~/Library/Application Support/PulsarTrace/events/
  2026-04-30.jsonl     ← today (current append target)
  2026-04-29.jsonl
  ...
  2026-04-01.jsonl     ← oldest kept
  (anything older deleted)
```

- One file per local day, named `YYYY-MM-DD.jsonl`.
- **JSON Lines**: one self-contained JSON object per line, UTF-8.
- Single combined stream — no per-type splitting; all event types are
  interleaved chronologically.
- **Daily rotation, 30-day retention.** Files older than 30 days are deleted on
  app launch and at the local-midnight rollover.
- Append-only. Events are never edited or removed.

### Cross-process serialisation

Every `EventWriter.append` acquires an advisory `flock(LOCK_EX)` on the
daily file before writing. This protects against the otherwise-possible
case where `pulsartrace-mac` and `pulsartrace-capture` (each running
their own `EventWriter`) append concurrently and split a JSONL line
mid-byte. An external consumer that opens the file while appends are
in flight should expect to retry a partial tail read — `EventWriter`
itself never produces a partial line, but the on-disk state is only
*atomically complete* between flock-acquired writes.

## Common envelope

Every event line carries these four envelope fields (R80):

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string | Event time, ISO-8601 UTC, second precision (`2026-04-30T14:30:05Z`). |
| `type` | string | The event type, e.g. `app_started`. |
| `id` | string | A unique event ID: `evt_` + a [ULID](https://github.com/ulid/spec). Lexicographically sortable by creation time. |
| `version` | integer | The schema version **of this event type**. Starts at 1, bumped only on a breaking change to that type's payload. |

The type-specific payload fields sit alongside the envelope in the same flat
JSON object.

## Versioning rules (integrator contract)

The schema is SemVer-stable per type, keyed off the envelope `version`:

- **Additive** — adding a new optional payload field is *not* a version bump.
  Consumers MUST ignore unknown fields, so a v1 consumer reading a v1 event with
  extra fields keeps working.
- **Breaking** — removing a field, renaming a field, or changing a field's type
  bumps that event type's `version`. A v1 consumer should check `version`
  before relying on fields that may have moved.
- Adding a brand-new event type is additive — consumers ignore types they do
  not recognize.

## Privacy

The events log NEVER contains (R84):

- audio bytes or anything that could reconstruct audio
- transcript text
- full user file paths — **basename only**

The events log MAY contain: user-assigned speaker names, recording IDs, model
names, and file hashes. (Speaker names are user-assigned and local-only; this is
the one place names are allowed, unlike the operational log.)

## Identifiers

- `evt_<ulid>` — event IDs (this log).
- `spk_<ulid>` — speaker IDs. **Stable forever**: a rename changes the
  speaker's `name`, never its `id`. Agents key off the `id` for stable identity
  across renames (R83). (Speaker events land in Epic 5.)
- `rec_<short>` — recording IDs.

## Event catalogue

### System

#### `app_started` (version 1)

Emitted once when a PulsarTrace process (engine or CLI) starts.

| Field | Type | Description |
|-------|------|-------------|
| `app_version` | string | PulsarTrace application version. |
| `macos_version` | string | Host macOS version, e.g. `26.3.1`. |

> Note: the PRD lists this payload as `{version, macos_version}`. Because the
> envelope already owns a `version` field (the schema version), the
> application-version field is serialized as `app_version` to avoid a JSON key
> collision. See `project-docs/DECISIONS.md` (D5).

```jsonl
{"app_version":"0.1.0-dev","id":"evt_01HW...","macos_version":"26.3.1","ts":"2026-04-30T14:30:05Z","type":"app_started","version":1}
```

#### `app_stopped` (version 1)

Emitted once when a PulsarTrace process exits cleanly. Same payload shape as
`app_started`.

```jsonl
{"app_version":"0.1.0-dev","id":"evt_01HW...","macos_version":"26.3.1","ts":"2026-04-30T15:12:48Z","type":"app_stopped","version":1}
```

#### `model_downloaded` (version 1)

Emitted once after a whisper model file is downloaded **and** its SHA-256
verified against the pinned hash (R54c, R54d). Category: `system`.

A download that fails or fails verification emits **nothing** — the partial /
corrupt file is deleted and the download retried (resuming via HTTP Range); only
a fully-verified model produces this event. So one `model_downloaded` line means
exactly one model is now cached and trustworthy.

| Field | Type | Description |
|-------|------|-------------|
| `model_name` | string | Short model name, e.g. `base`, `large-v3`. |
| `size_bytes` | integer | Verified file size in bytes. |
| `sha256` | string | Lowercase-hex SHA-256 the file was verified against. |
| `source_host` | string | Bare hostname the model came from, e.g. `huggingface.co`. Never a full URL — no query params, no path (privacy + no-telemetry). |

```jsonl
{"id":"evt_01KR...","model_name":"base","sha256":"60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe","size_bytes":147951465,"source_host":"huggingface.co","ts":"2026-05-16T01:59:45Z","type":"model_downloaded","version":1}
```

### Refinement lifecycle

These three events bracket a `pulsartrace refine` pass (Epic 4). They are
emitted in causal order: `refinement_started` before any work,
`refinement_completed` last; a failure emits `refinement_failed` instead of
`refinement_completed`.

#### `refinement_started` (version 1)

Emitted once when a refine pass begins, before any transcription/diarization.
Category: `refinement_lifecycle`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The recording being refined (`rec_<short>`). |
| `model_refine` | string | Whisper model used for the refine pass, e.g. `large-v3`, `base`. |

```jsonl
{"id":"evt_01KRQD...","model_refine":"base","recording_id":"rec_two-speakers-alternating","ts":"2026-05-16T03:26:32Z","type":"refinement_started","version":1}
```

#### `refinement_completed` (version 1)

Emitted once, last, after `final.md` and `metadata.json` are durably on disk.
Category: `refinement_lifecycle`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The refined recording. |
| `duration_seconds` | number | Wall-clock seconds the refine pass took. |
| `speakers_identified` | integer | Distinct speakers in the final transcript. |
| `speakers_new` | integer | Speakers not matched to the library. In Epic 4 there is no speaker library, so this equals `speakers_identified`. |
| `speakers_matched` | integer | Speakers matched to an existing library entry. Always `0` in Epic 4; meaningful from Epic 5. |

```jsonl
{"duration_seconds":7.67,"id":"evt_01KRQD...","recording_id":"rec_two-speakers-alternating","speakers_identified":2,"speakers_matched":0,"speakers_new":2,"ts":"2026-05-16T03:26:57Z","type":"refinement_completed","version":1}
```

#### `refinement_failed` (version 1)

Emitted when a refine pass aborts. Category: `refinement_lifecycle`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The recording the refine was attempted on. |
| `error_class` | string | Coarse, stable failure category: `input`, `transcription`, `diarization`, `io`. Never a raw error string with a path. |
| `retry_available` | boolean | Whether re-running `refine` could plausibly succeed (`false` for a bad input path). |

```jsonl
{"error_class":"diarization","id":"evt_01KRQD...","recording_id":"rec_demo","retry_available":true,"ts":"2026-05-16T03:30:00Z","type":"refinement_failed","version":1}
```

### File operations

A refine pass produces one of `final_md_written` / `final_md_rewritten` after
its `final.md` is on disk, plus `live_md_replaced_by_final` when it supersedes a
recording's `live.md`. These are causally paired with the `refinement_started`
that triggered them (see *Causal pairing* below).

#### `final_md_written` (version 1)

Emitted after `final.md` is durably on disk for the **first time** (no prior
`final.md` existed). Category: `file_operations`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The refined recording. |
| `path_basename` | string | Basename only — always `final.md`. Never a full path. |
| `sha256` | string | Lowercase-hex SHA-256 of the written file's bytes. |

```jsonl
{"id":"evt_01KRQD...","path_basename":"final.md","recording_id":"rec_two-speakers-alternating","sha256":"c2c71868d9e21ffd3f3192d32a033050fb2993ffacf1d15d16d77f425ba3df16","ts":"2026-05-16T03:26:48Z","type":"final_md_written","version":1}
```

#### `final_md_rewritten` (version 1)

Emitted when an **existing** `final.md` is replaced. Category: `file_operations`.
In Epic 4 the cause is a re-refine (R27); from Epic 5 a speaker rename/merge can
also trigger it. The prior file is preserved as `final.md.bak`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The refined recording. |
| `path_basename` | string | Always `final.md`. |
| `sha256` | string | Lowercase-hex SHA-256 of the new file's bytes. |
| `reason` | string | Why it was rewritten. Epic 4 emits `re_refine`; Epic 8's retroactive rewrites emit `speaker_renamed`, `speaker_merged`, `speaker_split`, `speaker_unmerged`, or `speaker_unsplit`. |

```jsonl
{"id":"evt_01KRQD...","path_basename":"final.md","reason":"re_refine","recording_id":"rec_two-speakers-alternating","sha256":"c2c71868d9e21ffd3f3192d32a033050fb2993ffacf1d15d16d77f425ba3df16","ts":"2026-05-16T03:26:57Z","type":"final_md_rewritten","version":1}
```

#### `live_md_replaced_by_final` (version 1)

Emitted when refinement supersedes a recording's `live.md`. The `live.md` is
preserved as `.live.md.bak`. Category: `file_operations`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The refined recording. |

```jsonl
{"id":"evt_01KRQD...","recording_id":"rec_demo","ts":"2026-05-16T03:30:00Z","type":"live_md_replaced_by_final","version":1}
```

#### `live_md_started` (version 1)

Emitted when the **live pass** (Epic 6) creates a recording's `live.md` at
session start (R35a) — before the first utterance, so an agent tailing the file
has an immediate "recording in progress" signal. Category: `file_operations`.

The file already carries the `<!-- pulsartrace:live -->` marker and the
`## Transcript — …` header when this event fires (the event is emitted *after*
the file + header are on disk — causal order, Hard Invariant #8).

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The recording whose live pass started. |
| `path_basename` | string | Basename only — always `live.md`. Never a full path. |

```jsonl
{"id":"evt_01KRQK...","path_basename":"live.md","recording_id":"rec_two-speakers-alternating","ts":"2026-05-16T05:21:54Z","type":"live_md_started","version":1}
```

Later in the same recording's life, the post-pass emits
`live_md_replaced_by_final` (above) when `final.md` supersedes the `live.md`.

### Speaker library

Epic 5 adds the persistent speaker library (`speakers.sqlite`). Every library
operation emits exactly one `speaker_*` event; the database's own health is
reported by the two `library_*` events. Speaker ids are `spk_<ulid>` and are
**forever stable** (R83) — a rename changes only the `name`.

> Privacy note: these events MAY carry user-assigned speaker names
> (`initial_name`, `old_name`, `new_name`). The events log is local-only and
> never leaves the device, so that is allowed. The *operational* log
> (`~/Library/Logs/PulsarTrace/`) must never contain a speaker name.

#### `speaker_created` (version 1)

A new speaker was added to the library — either a refinement cluster that
matched no existing speaker, or the new speaker produced by a `speaker_split`.

| Field | Type | Description |
|-------|------|-------------|
| `speaker_id` | string | Stable `spk_<ulid>` id. |
| `initial_name` | string | Name at creation — an `Unknown #N` placeholder for a refinement-discovered speaker. |
| `source_recording_id` | string | The recording whose refinement first surfaced this speaker. |

```jsonl
{"id":"evt_01HW...","initial_name":"Unknown #3","source_recording_id":"rec_4f2a","speaker_id":"spk_a1b2","ts":"2026-04-29T15:42:12Z","type":"speaker_created","version":1}
```

#### `speaker_renamed` (version 1)

A speaker's display name changed. The `speaker_id` is unchanged (R83).

| Field | Type | Description |
|-------|------|-------------|
| `speaker_id` | string | Stable id — unchanged by the rename. |
| `old_name` | string | The previous name. |
| `new_name` | string | The new name. |
| `applied_to_recordings` | array | Recordings whose `final.md` was rewritten as a result. **Empty** for an Epic 5 CLI rename — Epic 5 does not retroactively rewrite past `final.md` files (that is Epic 8 scope, project-docs/DECISIONS.md D16). |

```jsonl
{"applied_to_recordings":[],"id":"evt_01HX...","new_name":"Steve","old_name":"Unknown #3","speaker_id":"spk_a1b2","ts":"2026-04-30T09:14:33Z","type":"speaker_renamed","version":1}
```

#### `speaker_merged` (version 1)

Two speakers were merged: `merged_speaker_id` is soft-deleted, its appearances
re-attributed to `primary_speaker_id`, whose centroid is recomputed.

| Field | Type | Description |
|-------|------|-------------|
| `primary_speaker_id` | string | The surviving speaker. |
| `merged_speaker_id` | string | The speaker folded in (soft-deleted, recoverable). |
| `applied_to_recordings` | array | Recordings rewritten. Empty in Epic 5 (D16). |

#### `speaker_split` (version 1)

A subset of one speaker's appearances was peeled into a brand-new speaker.
Always followed by a `speaker_created` for the new speaker.

| Field | Type | Description |
|-------|------|-------------|
| `original_speaker_id` | string | The speaker the appearances came from. |
| `new_speaker_id` | string | The new speaker holding the peeled-off appearances. |
| `applied_to_recordings` | array | Recordings rewritten. Empty in Epic 5 (D16). |

#### `speaker_deleted` (version 1)

A speaker was soft-deleted (R32b). The record is hidden but recoverable for 30
days via the "Recently deleted" view.

| Field | Type | Description |
|-------|------|-------------|
| `speaker_id` | string | The deleted speaker. |
| `soft_delete` | bool | Always `true` — Epic 5 deletes are always soft. |
| `recoverable_until` | string | ISO-8601 UTC instant after which recovery is no longer possible. |

```jsonl
{"id":"evt_01HW...","recoverable_until":"2026-05-30T14:30:05Z","soft_delete":true,"speaker_id":"spk_a1b2","ts":"2026-04-30T14:30:05Z","type":"speaker_deleted","version":1}
```

#### `speaker_undeleted` / `speaker_unmerged` / `speaker_unsplit` (version 1)

The undo operations for delete / merge / split (R32b — one-click undo).

| Event | Fields |
|-------|--------|
| `speaker_undeleted` | `{speaker_id}` |
| `speaker_unmerged` | `{primary_speaker_id, merged_speaker_id}` |
| `speaker_unsplit` | `{original_speaker_id, new_speaker_id}` |

#### `speaker_centroid_updated` (version 1)

A returning speaker's centroid was refined by a new appearance via the
count-weighted running mean (R30).

| Field | Type | Description |
|-------|------|-------------|
| `speaker_id` | string | The speaker whose centroid was refined. |
| `recording_id` | string | The recording whose appearance was averaged in. |
| `appearance_count` | int | The speaker's appearance count *after* this update. |

```jsonl
{"appearance_count":3,"id":"evt_01HW...","recording_id":"rec_4f2a","speaker_id":"spk_a1b2","ts":"2026-04-30T14:30:05Z","type":"speaker_centroid_updated","version":1}
```

#### `library_backup_created` (version 1)

The `speakers.sqlite` file was copied to its last-good `.bak` ahead of a
mutating write (R32a resilience). Category: `system`.

| Field | Type | Description |
|-------|------|-------------|
| `path_basename` | string | Basename of the backup — `speakers.sqlite.bak`. |
| `sha256` | string | Lowercase-hex SHA-256 of the backed-up database file. |

#### `library_corruption_detected` (version 1)

The `speakers.sqlite` database failed to open / integrity-check on launch, and
recovery from the last-good backup was attempted. Category: `system`.

| Field | Type | Description |
|-------|------|-------------|
| `path_basename` | string | Basename of the corrupt database — `speakers.sqlite`. |
| `recovered_from_backup` | bool | `true` when a usable backup was found and restored. |

### Recording lifecycle

Epic 7 adds real device capture. `pulsartrace-capture` — the only process that
holds TCC permissions — is the authoritative emitter of these four events: it
owns the audio hardware and the session clock. They bracket one recording
session: `recording_started` first, `recording_stopped` last, with any number
of `recording_paused` / `recording_resumed` pairs in between (system sleep, R7;
audio-device change, R8). Each `recording_resumed` is paired with the
`recording_paused` that preceded it (causal order, Hard Invariant #8).

#### `recording_started` (version 1)

Emitted once when a recording session begins producing audio — after hardware
capture has started and the first frame has reached a socket, so a consumer
reacting to this event knows audio is genuinely flowing. Category:
`recording_lifecycle`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The recording (`rec_<short>`). |
| `output_dir_basename` | string | Basename of the recording's output folder — never a full path. |
| `mic_device` | string | The microphone in use (its localized name), or `none`. |
| `system_audio_enabled` | boolean | Whether system-audio capture is on for this session (R6). |
| `model_live` | string | Whisper model name used for the live pass, e.g. `base`. |

```jsonl
{"id":"evt_01KR...","mic_device":"MacBook Air Microphone","model_live":"base","output_dir_basename":"meeting-2026-05-16","recording_id":"rec_4f2a","system_audio_enabled":true,"ts":"2026-05-16T14:30:05Z","type":"recording_started","version":1}
```

#### `recording_paused` (version 1)

Emitted when capture pauses mid-session. Category: `recording_lifecycle`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The recording. |
| `reason` | string | Stable code: `sleep` (Mac slept, R7), `device_change` (active audio device changed, R8), or `stall_recovery` (a capture stream silently stopped delivering audio and the capture daemon restarted it). |

```jsonl
{"id":"evt_01KR...","reason":"sleep","recording_id":"rec_4f2a","ts":"2026-05-16T14:42:11Z","type":"recording_paused","version":1}
```

#### `recording_resumed` (version 1)

Emitted when capture resumes after a pause. Always paired with — and emitted
after — the `recording_paused` that preceded it. Category: `recording_lifecycle`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The recording. |
| `reason` | string | The reason capture had paused — `sleep`, `device_change`, or `stall_recovery`. |

```jsonl
{"id":"evt_01KR...","reason":"sleep","recording_id":"rec_4f2a","ts":"2026-05-16T14:48:33Z","type":"recording_resumed","version":1}
```

#### `recording_stopped` (version 1)

Emitted once when a recording session ends and both audio streams are flushed.
Category: `recording_lifecycle`.

| Field | Type | Description |
|-------|------|-------------|
| `recording_id` | string | The recording. |
| `duration_seconds` | number | Total wall-clock seconds captured. |
| `reason` | string | Stable code: `user_stop`, `force_quit`, `sleep_timeout`, or `disk_full`. |

```jsonl
{"duration_seconds":1843.5,"id":"evt_01KR...","reason":"user_stop","recording_id":"rec_4f2a","ts":"2026-05-16T15:00:48Z","type":"recording_stopped","version":1}
```

#### `permission_changed` (version 1)

Emitted by `pulsartrace-capture` when a TCC permission it depends on changes
state — checked at launch and on the system's TCC-change notification.
Category: `system`.

| Field | Type | Description |
|-------|------|-------------|
| `permission` | string | Which permission — `microphone` or `screen_recording`. |
| `granted` | boolean | Whether the permission is now granted. |

```jsonl
{"granted":true,"id":"evt_01KR...","permission":"screen_recording","ts":"2026-05-16T14:29:50Z","type":"permission_changed","version":1}
```

### Causal pairing

Some events must be emitted together, in causal order (PRD §8.13, invariant 8).
A file-operation event is never emitted without the cause event that triggered
it, and the cause always precedes the effect in the log:

- A refine pass emits `refinement_started` first; its `final_md_written` /
  `final_md_rewritten` (and any `live_md_replaced_by_final`) follow once the
  files are durably on disk; `refinement_completed` is last. So the order
  within one refine is always `refinement_started` → `live_md_replaced_by_final`
  (if any) → `final_md_written` | `final_md_rewritten` → `refinement_completed`.
- A `speaker_renamed` / `speaker_merged` / `speaker_split` — and the undo
  operations `speaker_unmerged` / `speaker_unsplit` — performed in **Epic 8**
  (the menubar editor) is followed, in causal order, by a `final_md_rewritten`
  for each affected past recording whose `final.md` actually changed; its
  `applied_to_recordings` lists exactly those recordings (a recording the edit
  did not textually change is neither rewritten nor listed). `speaker_undeleted`
  emits no `final_md_rewritten` — a soft-delete never rewrote any `final.md`.
- In **Epic 5**, a `speaker_renamed` / `speaker_merged` from the
  `pulsartrace speakers` CLI updates the library only — it does **not**
  retroactively rewrite past `final.md` files, so `applied_to_recordings` is
  empty and no `final_md_rewritten` is paired with it (project-docs/DECISIONS.md D16). The
  new name takes effect on the next `pulsartrace refine` of a recording, when
  reconciliation applies it. A refine pass that reconciles speakers emits its
  `speaker_created` / `speaker_centroid_updated` events between
  `refinement_started` and `refinement_completed`.
