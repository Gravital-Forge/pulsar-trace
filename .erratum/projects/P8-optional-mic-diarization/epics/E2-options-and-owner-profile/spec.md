# PT-P8-E2 · Options sidecar + owner voice profile — Specification

**Status:** Frozen · **Opened:** 2026-07-29 · **Closed:** 2026-07-29

## Intent

Implements PT-P8-R2 and PT-P8-R3; touches components PT-C4 (Refinement Pipeline), PT-C5 (Speaker
Library neighborhood — the profile lives beside it, never inside it), and PT-C11 (contracts).
Two new persistence pieces: (1) `RecordingOptions`, the per-recording **input** sidecar
(`options.json` in the recording folder, tolerant decode, absent ⇒ defaults) that later epics read
in both passes; (2) `OwnerVoiceProfileStore`, a single-record atomic-JSON store
(`owner-profile.json` under application support) holding the owner centroid in the unified
embedding space (PT-R112), pinned to the diarization model revision with archive-and-reset on
mismatch (PT-R113 semantics), updated by inlier-gated running mean. On top of the stores: the
mic-embedding extraction used by passive learning (diarize the mic WAV, pick the cluster dominant
over the *deduped* mic segments from E1), the passive-learning hook in both refine paths, and the
one-shot backfill API (newest-first over existing recordings, fixed cap) that E6 triggers from the
settings toggle.

Design notes locked here: the profile is a JSON sidecar, not a `speakers.sqlite` table — a single
record needs atomic replace (existing `AtomicFile`), not SQL, and staying out of the library
guarantees the reconciler/edit surface can never see it (PT-P8-R3). Passive learning runs on every
ordinary refine (no maturity cap — refine cost is dominated by transcription, and the queue is
background); it diarizes the mic WAV via the same `Diarizer` the pipeline already holds.

## Acceptance criteria

- `options.json` round-trips `diarize_mic`; a missing or malformed file decodes to defaults and
  never fails a pass; `RecordingFolder.FileName.options` names it.
- `OwnerVoiceProfileStore`: empty-store seed, inlier accept (running mean + `sampleCount`),
  outlier reject, model-revision mismatch archives (`owner-profile.<rev8>.bak.json`) and resets,
  weighted-removal (`remove(embedding:)`) inverts one accepted sample.
- A `RefinementPipeline.run` / `ResumableRefiner.run` over a mic-bearing, non-mic-diarized
  recording updates the profile from the dedup-surviving mic speech; a mic-less recording leaves
  it untouched.
- `OwnerProfileBackfill.run` over a root with N recording folders processes newest-first, stops at
  the cap or on centroid stabilization, and produces a usable profile.
- Every store write emits `owner_profile_updated` (no embedding values in the payload — PT-R84).

## Tasks

- PT-P8-E2-T1 — `RecordingOptions` sidecar type + tolerant IO
- PT-P8-E2-T2 — `OwnerVoiceProfileStore` (seed / inlier gate / running mean / revision archive / removal)
- PT-P8-E2-T3 — Mic-embedding extraction + passive-learning hook in both refine paths
- PT-P8-E2-T4 — `OwnerProfileBackfill` (newest-first, capped) + `owner_profile_updated` event
