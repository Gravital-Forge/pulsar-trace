# PT-P8-E2 · Options sidecar + owner voice profile — Completion Record

**Status:** Frozen · **Closed:** 2026-07-29

## What was built

Commit 6d4ac4a, four pieces:

- **`RecordingOptions`** — the per-recording *input* sidecar (`options.json`,
  `RecordingFolder.FileName.options` + `optionsURL`): snake_case Codable with a tolerant decoder
  (missing/malformed/unknown-keys ⇒ `.defaults`, never throws to a pass), atomic writes via
  `AtomicFile`.
- **`OwnerVoiceProfileStore`** — a single-record atomic-JSON actor at `AppPaths.ownerProfileURL`
  (`owner-profile.json`, beside — never inside — the speaker library). Seed on empty; same-revision
  inlier (cosine ≥ 0.45, `inlierThreshold`) running-means the centroid and bumps `sampleCount`;
  outlier rejected; revision mismatch archives to `owner-profile.<rev8>.bak.json` and reseeds
  (PT-R113 semantics); `remove(embedding:)` weighted-subtracts one sample, emptying the store at
  count 1; `match(embedding:modelRevision:)` is read-only and nil on empty/mismatch (live-pass
  safe). `matchThreshold = 0.45` pinned by test.
- **`OwnerProfileLearner`** — passive learning (PT-P8-R3 (a)): diarize the mic WAV, pick the cluster
  with greatest span-overlap against the *dedup-surviving* mic segments (E1), feed the store.
  Non-fatal by design; hooked into both refine paths after the merge, gated on `diarizeMic == false`
  \+ mic-stream presence + a store being wired. The production queue passes
  `OwnerVoiceProfileStore(fileURL: paths.ownerProfileURL)` (via the queue's `paths`, so E2E
  re-rooting holds).
- **`OwnerProfileBackfill`** — one-shot first-enable build (PT-P8-R3 (d)): newest-first by folder
  mtime, skips mic-less and stamp-on folders, cap 10, early exit after 3 consecutive accepted
  samples each moving the centroid by cosine < 0.01. Emits one `owner_profile_updated` summary
  event. `OwnerProfileUpdatedEvent` (schema v1: `source`, `sample_count` — no embedding values,
  PT-R84) registered under the `speaker_library` category.

## Deltas from the task skeleton

- The T4 test draft mutated a captured array inside a `@Sendable` closure — a Swift 6 data-race
  error; replaced with a small actor box, same assertions.
- The event-registry category was unnamed in the task; registered under `.speakerLibrary`.

## Empirical findings worth keeping

- Passive learning in the queue path re-diarizes the mic WAV on every ordinary mic-bearing refine —
  a second FluidAudio run per refine. Accepted per the epic's design note (refine cost is
  transcription-dominated, queue is background); a cost note, not a correctness issue.

## Requirements satisfied

- **PT-P8-R2** — sidecar round-trip, defaults-on-absence, never fails a pass.
- **PT-P8-R3** (storage, sources (a) and (d), inlier gate, revision migration) — source (b)
  (mic-diarized refine) landed in E3; source (c) (explicit designation) in E5.

## To flow into the product layer

At close-out: PT-P8-R2's mint records `options.json` as the input-sidecar contract (`metadata.json`
untouched as an input channel, PT-P8-D5); PT-P8-R3's mint records the profile file, thresholds, and
archive naming as implementation anchors.
