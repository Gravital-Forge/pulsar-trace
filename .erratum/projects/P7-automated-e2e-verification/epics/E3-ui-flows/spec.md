# PT-P7-E3 · UI End-to-End Flows — Specification

**Status:** Open · **Opened:** 2026-07-02

## Intent

Implements the deep-flow half of PT-P7-R4 on the E2 harness; touches the Menubar Application
(PT-C16) only through its accessibility surface — these are tests, not app changes. Four flows on
top of the floor: a full record → stop → refine pass over fixture capture (PT-P7-E1) with artifact
and event assertions; settings persistence across an app relaunch; speaker rename with the
retroactive `final.md` rewrite; and merge with the undo toast round-trip, both against the
`SeededHome` state (PT-P7-D6). Closes with the checklist annotation pass: every
`docs/release-smoke-test.md` item the suites now cover gets marked as automated.

## Acceptance criteria

- The record flow launches with the paired fixture WAVs and a shared models directory, starts
  recording from the menubar panel, observes `live.md` growing, and — after the engine's fixture-EOF
  self-exit — waits for the queued refinement to produce a well-formed `final.md`; it asserts the
  live/final markers, at least one utterance line, and the causal event order in the isolated home's
  events log (exact type strings pinned from the events-log contract, PT-C6).
- Settings persistence: a toggle changed through the UI survives `terminate()` + relaunch on the
  same suite; the seeded output folder still renders.
- Rename: renaming Alice → Alicia rewrites both seeded `final.md` files (content asserted on disk),
  leaves `.bak` siblings, and logs `speaker_renamed` before its `final_md_rewritten` events. Merge:
  merging Carol into Alice shows the confirmation with a rewrite count, rewrites the affected
  transcript, surfaces the undo toast, and undo restores both library and transcript.
- Every covered checklist item in `docs/release-smoke-test.md` carries an automation marker naming
  its suite; uncovered items are untouched.

## Tasks

- PT-P7-E3-T1 — Record → stop → refine over fixture capture, with artifact + event assertions.
- PT-P7-E3-T2 — Settings persistence across relaunch.
- PT-P7-E3-T3 — Speaker rename flow with retroactive rewrite assertions.
- PT-P7-E3-T4 — Merge + undo-toast round-trip.
- PT-P7-E3-T5 — Mark automated items in `docs/release-smoke-test.md`.
