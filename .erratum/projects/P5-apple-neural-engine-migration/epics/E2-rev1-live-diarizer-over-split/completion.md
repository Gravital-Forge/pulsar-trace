# PT-P5-E2-rev1 · Live-Diarizer Over-Split — Completion Record

**Status:** Frozen · **Closed:** 2026-06-16

## What was built

A live-only clustering threshold was implemented and then reverted; the shipped product is unchanged.

The experiment split `DiarizerEngine`'s single shared `OfflineDiarizerManager` into a `refineManager`
(FluidAudio default `clustering.threshold = 0.6`) and a `liveManager` carrying a raised AHC threshold
`liveClusteringThreshold = 1.05` (a Euclidean distance on unit-normalized WeSpeaker embeddings,
under the √2 ≈ 1.414 ceiling that `OfflineDiarizerConfig.validate()` enforces), with live-path
key-count guard tests. It was calibrated so a real two-speaker recording produced exactly two
provisional keys while the committed fixtures held their counts.

It was reverted in full (`c0ddbda`): the single shared manager at threshold 0.6 was restored and the
two guard tests removed. The over-split it targeted was never the reported problem — the field
failure was the **opposite**, an **under-split** in which short interjections collapse into whoever
is already speaking, and raising the AHC merge distance aggravates under-split. A later threshold
sweep independently confirmed the clustering threshold is a non-lever here (the speakers were already
highly separable). The real cause was pursued in PT-P5-E2-rev2.

## Deltas from the spec

The epic's hypothesis (an over-split curable by a live-only threshold) was wrong, so its tasks
concluded in a revert rather than a shipped change. Net effect on the product: none — the change
never reached the integration branch, and live and refine share one manager at threshold 0.6.

## Requirements satisfied

None — the experiment was reverted; it introduces no requirement and leaves no net architecture
change. The diarization decision PT-P5-D5 records the investigation and its outcome.

## To flow into the product layer

Nothing to reconcile — no requirement, no component change. The lesson (the clustering threshold is
not the lever; the real failure is under-split / a wedge) carries into PT-P5-E2-rev2.
