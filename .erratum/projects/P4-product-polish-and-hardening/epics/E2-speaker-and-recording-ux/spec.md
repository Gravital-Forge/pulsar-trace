# PT-P4-E2 · Speaker & Recording UX — Specification

**Status:** Frozen · **Opened:** 2026-05-31 · **Closed:** 2026-06-09

## Intent

Refine the speaker and recording experience and keep the speaker set meaningful: speaker pills per
recording, deduped speaker rows, smart live-transcript auto-scroll, and "don't recognize this
speaker" delisting with a non-person per-line fallback that earns no speaker identity (PT-P4-R2).
Touches the Menubar (PT-C16), the Speaker Library (PT-C5), and the retroactive rewriter (PT-C4).

## Acceptance criteria

- A delisted speaker is removed from people and its affected transcripts rewritten.
- A per-line fallback for speech overlapping no diarized turn labels the line but earns no speaker
  pill or metadata entry; duplicate speaker rows do not appear.
- The live transcript follows new lines when at the bottom and offers a "jump to newest" affordance
  otherwise.

## Tasks

- PT-P4-E2-T1 — Speaker pills per recording row; dedupe speaker rows in metadata
- PT-P4-E2-T2 — Smart auto-scroll for the live transcript
- PT-P4-E2-T3 — "Don't recognize this speaker" delist + retroactive rewrite; non-person fallback
