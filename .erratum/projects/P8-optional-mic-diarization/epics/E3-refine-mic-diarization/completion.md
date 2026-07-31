# PT-P8-E3 · Mic diarization in the refine pass — Completion Record

**Status:** Frozen · **Closed:** 2026-07-29

## What was built

Commit f8f3d4d:

- **Stream-agnostic diarizer:** `diarizeSystemStream(wavPath:)` → `diarizeStream(wavPath:)`, clean
  rename across all call sites (pipeline, queue wiring, E2's learner hook, tests).
- **Conditional mic stage in both refine paths:** when the stamp is on and a mic stream exists, a
  `diarizingMic` stage (new case in `RefinementPipeline.Stage` and `RefinementJobState.Stage`; old
  persisted JSONL still decodes) diarizes the mic WAV and persists it to **`mic-diarization.json`**
  (`MicDiarizationSidecar`, tolerant read → nil) so E5's owner edits have cluster embeddings without
  re-diarizing. The queue stage mirrors the system stage's actual resume mechanics (D-Q7
  cancel-retry; no result checkpoint — re-runs on resume, like system diarization does).
- **`MicChannelAttribution`** — at most one `You`: best owner-profile match at/above
  `matchThreshold`, fail-safe (no profile / revision mismatch / no match ⇒ zero `You`); the `You`
  cluster updates the profile (source `mic_diarized_refine`); remaining clusters reconcile through
  the shared `SpeakerReconciler`, which gained `excludingSpeakers:` so the owner cluster can never
  enroll in the library. Reconciler failure is non-fatal (raw labels kept), matching the
  system-stream posture.
- **Merge tail + contract:** `mergeStreams` labels deduped mic segments per cluster via
  `DiarizationMerge.speakerLabels` with the display↔raw round-trip the system path uses;
  `MergedTranscript.micLabels` carries the mic-attributed label set. `RefinementMetadata` is
  **schema v3**: new `mic_diarized`, `is_microphone` loosened to per-stream provenance (several rows
  may carry it; `You` keeps `speaker_id: null`), tolerant decode of v2 files.
  `FinalMarkdownRewriter` round-trips `micDiarized` through both metadata-reconstruction sites.
  `DiarizationResult` gained fixture-shaped `Codable` (seconds durations, `label → vector`
  embeddings object) for the sidecar.
- **Live-model E2E** (`MicDiarizedRefineTests`): stamp-on refine over the paired fixture with a
  profile seeded from the fixture's own mic audio (metadata v3, `mic_diarized: true`, sidecar
  written, `You` row with null id), and revert-by-re-refine back to the single-`You` shape.

## Deltas from the task skeleton

- `buildMetadata` reshaped to take `merged:` + `micDiarized:` (the draft's suggested shape) so the
  per-stream mic-label set and id map travel together.
- The draft's owner-match `break`-on-nil kept, with the reasoning made explicit: `match` returns nil
  only for store-level states (empty / revision mismatch) that are identical for every embedding in
  the pass, so the first nil is dispositive.
- Incremental-build note: adding the trailing defaulted `micDiarized:` to the public metadata init
  changed its mangled symbol; stale test objects needed a forced recompile. Cold builds unaffected.

## Empirical findings worth keeping

- **The paired fixture's `mic.wav` is single-voice** (ElevenLabs monologue; diarizer reports one
  cluster). Per the task's fixture-reality-check the E2E asserts the single-cluster path; the
  two-voice guest assertion was deferred to E4's minted fixture and closed there.
- Mic-diarization failure is fatal to a stamp-on refine (`RefineError.diarization`), the same
  posture as system diarization; only reconciliation inside attribution is non-fatal.
- The sidecar's duration coding rounds to milliseconds — exact for the round-trip test, lossy only
  below ms. Revisit if a consumer ever needs sub-ms fidelity.

## Requirements satisfied

- **PT-P8-R1** (refine half) — stamp-on mic diarization in both paths; stamp-off byte-identical.
- **PT-P8-R4** — fail-safe `You` among mic clusters; at most one.
- **PT-P8-R5** — mic guests are ordinary shared-library speakers; cross-channel reconciliation
  asserted via shared embedding fixtures.
- **PT-P8-R10** (metadata half) — schema v3, `mic_diarized`, per-stream `is_microphone`, v2 files
  parse unchanged.

## To flow into the product layer

At close-out: PT-R17's supersession by PT-P8-R1; the `metadata.json` contract doc gains the v3
fields; `mic-diarization.json` joins the recording-folder inventory; the reconciler's
`excludingSpeakers` and the attribution module become `implemented_by` anchors for R4/R5.
