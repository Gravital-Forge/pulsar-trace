# PulsarTrace events log schema

The events log is a system-wide, append-only, machine-readable record of every
significant operation in PulsarTrace. It is a **public API surface** alongside
`live.md` and `final.md` (PRD §8.13, R85): LLM agents and external tools consume
it to understand "what's happened in PulsarTrace recently."

> Status: Epic 1 establishes the envelope contract, the rotation/retention
> behavior, and the `app_started` / `app_stopped` system events. Later epics
> append their event types to the catalogue below as they implement emission.

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
> collision. See `DECISIONS.md` (D5).

```jsonl
{"app_version":"0.1.0-dev","id":"evt_01HW...","macos_version":"26.3.1","ts":"2026-04-30T14:30:05Z","type":"app_started","version":1}
```

#### `app_stopped` (version 1)

Emitted once when a PulsarTrace process exits cleanly. Same payload shape as
`app_started`.

```jsonl
{"app_version":"0.1.0-dev","id":"evt_01HW...","macos_version":"26.3.1","ts":"2026-04-30T15:12:48Z","type":"app_stopped","version":1}
```

### Reserved for later epics

The following types are specified in PRD §8.13 and will be documented here in
full as each epic implements emission. They are listed now so integrators see
the planned surface:

- **Recording lifecycle** (Epic 6/7): `recording_started`, `recording_paused`,
  `recording_resumed`, `recording_stopped`.
- **Refinement lifecycle** (Epic 4): `refinement_started`,
  `refinement_completed`, `refinement_failed`.
- **Speaker library** (Epic 5): `speaker_created`, `speaker_renamed`,
  `speaker_merged`, `speaker_split`, `speaker_deleted`, `speaker_undeleted`,
  `speaker_unmerged`, `speaker_unsplit`, `speaker_centroid_updated`.
- **File operations** (Epic 4/6): `live_md_started`, `final_md_written`,
  `final_md_rewritten`, `live_md_replaced_by_final`.
- **System** (Epic 2/7): `model_downloaded`, `permission_changed`,
  `library_backup_created`, `library_corruption_detected`.

### Causal pairing

Some events must be emitted together, in causal order (PRD §8.13, invariant 8):
a `speaker_renamed` / `speaker_merged` / `speaker_split` is always followed by
the corresponding `final_md_rewritten` for each affected recording. A file
change is never emitted without the cause event that triggered it.
