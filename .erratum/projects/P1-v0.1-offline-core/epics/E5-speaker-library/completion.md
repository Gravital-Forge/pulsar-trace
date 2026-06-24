# PT-P1-E5 · Speaker Library — Completion Record

**Status:** Frozen · **Closed:** 2026-05-16

## What was built

`SpeakerLibrary` is a durable store over the platform SQLite module (`SQLiteDatabase`) in WAL mode,
holding per-speaker name, centroid, appearance count, last-seen, and a sample-audio path, keyed by a
stable `spk_<ulid>` ID (`Speaker`). `Centroid` updates the per-speaker centroid by a count-weighted
running mean; `SpeakerReconciler` matches a recording's post-pass speaker clusters against the store
by cosine similarity, adding new speakers and refining existing centroids, and refuses matches across
incompatible model revisions. Destructive operations are soft-deleted with a multi-week undo window,
and a last-good backup auto-restores on corruption. The `speakers` CLI lists, renames, merges, and
deletes; rename and merge update only the library in this project (retroactive transcript rewrite is
deferred — PT-P1-D16). A returning speaker auto-applies its name on the next recording.

This completes the v0.1 milestone.

## Deltas from the spec

None.

## Requirements satisfied

- **PT-P1-R7** — `Sources/PulsarTraceEngine/SpeakerLibrary/` — `SpeakerLibrary.swift`,
  `Speaker.swift`, `SQLiteDatabase.swift`, `Centroid.swift`, `SpeakerReconciler.swift`;
  `Sources/pulsartrace/SpeakersCommand.swift`

## To flow into the product layer

- Mint component: Speaker Library.
- Mint product requirements PT-R22 (reconcile clusters with the library), PT-R23 (update the library
  at post-pass), PT-R28 (speaker store schema), PT-R30 (running-mean centroids), PT-R32a (WAL
  journaling), PT-R32b (soft-delete with undo), PT-R49 (`speakers` CLI), PT-R83 (stable speaker IDs).
