# PT-C6 · Events Log — Contract

The normative specification of the event stream, a public API surface (PT-R85). External agents may
depend on it; changes follow the versioning rule (PT-R89).

## Location and rotation

Events are written to a single combined per-day file, `events/YYYY-MM-DD.jsonl`, under the product's
application-support directory. One file per local day; files are rotated daily and pruned after the
retention window (PT-R78, PT-R79).

## Record shape

Each line is one self-contained JSON object. Every event carries the common envelope (PT-R80):

- `ts` — ISO-8601 timestamp
- `type` — event type name
- `id` — a ULID, unique per event
- `version` — the type's schema version (each type evolves independently — PT-R81)

Type-specific fields sit alongside the envelope. Consumers ignore unknown fields.

## Content rule

The log never contains audio, transcript text, or full filesystem paths. It may contain
user-assigned speaker names, recording IDs, model identities, and content hashes (PT-R84).

## Event families present at this stage

Each significant operation emits exactly one event (PT-R82):

- **Lifecycle** — `app_started`, `app_stopped` (the app-version field serializes as `app_version`).
- **Model** — `model_downloaded`.
- **Refinement** — `refinement_started`, `refinement_completed`, `refinement_failed`.
- **File operations** — the final-transcript write/rewrite events.
- **Speaker library** — new/matched counts on refinement completion, and the speaker-mutation family
  (rename / merge / split / delete), each paired with a final-transcript-rewrite event.
- **Owner voice profile** — `owner_profile_updated` when the owner voiceprint changes (passive
  learning, a mic-diarized refine, first-enable backfill), and the microphone-owner reassignment pair
  `owner_designated` / `owner_demoted`, each emitted before its paired final-transcript-rewrite event
  in causal order. These carry only counts and ids — never embedding values (PT-R84, PT-R144).
- **Recording lifecycle** — `recording_started`, `recording_paused`, `recording_resumed`,
  `recording_stopped` (pause/resume carry a reason, e.g. sleep, device change, or stall recovery).
- **Live transcript** — `live_md_started`, and `live_md_replaced_by_final` at refinement.
- **Permission** — `permission_changed` for microphone and screen-recording grants.

The registry of types lives with the Events Log component; each type evolves its own version under
the common envelope and content rule.
