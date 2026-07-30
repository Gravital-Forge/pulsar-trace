# PT-P8-E3 · Mic diarization in the refine pass — Specification

**Status:** Open · **Opened:** 2026-07-29

## Intent

Implements the refine half of PT-P8-R1, plus PT-P8-R4, PT-P8-R5, and PT-P8-R10; touches components
PT-C3 (Diarization Engine), PT-C4 (Refinement Pipeline), PT-C5 (Speaker Library), PT-C11
(Transcript Output), PT-C17 (job state). When a recording's `options.json` stamp is on, both refine
paths diarize the mic WAV (the diarizer entry point generalizes from `diarizeSystemStream` to
stream-agnostic `diarizeStream`), attribute the owner cluster to `You` via the E2 profile
(fail-safe: no confident match ⇒ no `You`), reconcile the remaining clusters into the shared
speaker library exactly like system clusters, and render per-cluster mic labels in `final.md` and
`metadata.json` (new `mic_diarized` field, `is_microphone` loosened to per-stream provenance,
`schema_version` → 3). The mic `DiarizationResult` is persisted as `mic-diarization.json` in the
recording folder so E5's owner-reassignment edits have cluster embeddings without re-diarizing.

## Acceptance criteria

- Stamp off ⇒ output identical to pre-E3 behavior (all suites green with no test edits beyond
  metadata schema-version pins).
- Stamp on ⇒ mic segments carry per-cluster labels: `You` for the owner-profile match at/above
  `OwnerVoiceProfileStore.matchThreshold`; library names / `Unknown #N` for the rest; at most one
  `You`; no profile or no match ⇒ zero `You` lines (PT-P8-R4).
- Mic guests appear in the library with `spk_` ids and running-mean centroids; a guest seen on the
  system stream in another recording reconciles to the same id (PT-P8-R5 — asserted via shared
  embedding fixtures).
- `metadata.json`: `schema_version == 3`, `mic_diarized` present, mic speakers carry
  `is_microphone: true` (several rows may), `You` keeps `speaker_id: null` (PT-P8-R10).
- `mic-diarization.json` written on every mic-diarized refine; refine works when it is absent.
- Events: `refinement_completed` unchanged; `owner_profile_updated(source: mic_diarized_refine)`
  emitted when the `You` cluster updates the profile.

## Tasks

- PT-P8-E3-T1 — Stream-agnostic diarizer + conditional mic-diarization stage in both refine paths
- PT-P8-E3-T2 — `MicChannelAttribution`: owner match + guest reconciliation
- PT-P8-E3-T3 — Merge tail + `metadata.json` evolution (schema v3)
- PT-P8-E3-T4 — End-to-end mic-diarized refine over the paired fixture
