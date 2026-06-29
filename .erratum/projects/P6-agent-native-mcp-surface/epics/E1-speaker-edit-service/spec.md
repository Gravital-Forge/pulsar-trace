# PT-P6-E1 · Speaker Edit Service — Specification

**Status:** Frozen · **Opened:** 2026-06-26 · **Closed:** 2026-06-29

## Intent

Extract the speaker-edit orchestration — mutate the library with the event suppressed, run the
`FinalMarkdownRewriter` over the affected appearances, then emit the `speaker_*` cause before its
`final_md_rewritten` effects — out of the menubar's `SpeakerEditorViewModel` and into a reusable
engine actor, so the menubar editor, the MCP server (PT-P6-E4), and the CLI (PT-P6-E6) all produce
identical file and event effects. Implements PT-P6-R9. Reshapes the Speaker Library (PT-C5) and the
Refinement Pipeline's retroactive rewriter (PT-C4), introduces the Speaker Edit Service
(provisional, its component ID minted at close-out), and refactors the Menubar Application (PT-C16).
The view model's externally-observable behaviour does not change — the existing
`SpeakerEditorViewModel` suite is the parity guard.

## Acceptance criteria

- A new `SpeakerEditService` actor in `PulsarTraceEngine`, injected with the speaker library, the
  event writer, and a `FinalMarkdownRewriter`, exposes rename / merge / split / unmerge / unsplit /
  delete / undelete / delist / undelist; each rewriting operation takes the current output-folder
  roots as a per-call parameter (the roots can change between edits).
- An edit through the service produces the same `final.md` rewrite and the same events, in the same
  causal order (`speaker_*` before `final_md_rewritten`), as the menubar editor produced before. The
  canonical name validation, the unchanged-name no-op, and the mic-speaker (`"You"`) delist
  rejection live in the service so every caller enforces them.
- `SpeakerEditorViewModel` delegates each mutating method to the service and keeps its UI concerns
  (`isRewriting`, the undo toast, `reload`, `lastError`) and its cheap pre-checks; the existing
  `SpeakerEditorViewModel` suite passes unchanged.
- New `SpeakerEditService` tests cover each operation directly — the path the MCP and CLI callers
  take when they bypass the view model.

## Tasks

- PT-P6-E1-T1 — `SpeakerEditService` skeleton: the `SpeakerEditResult` and `SpeakerEditError` types,
  the actor's initializer, the shared static name validator, and the paired-rewrite-event emitter.
- PT-P6-E1-T2 — Service `rename` and `merge`: suppress the library event, rewrite, emit the cause
  then the effects; `rename` no-ops (no rewrite, no event) when the name is unchanged.
- PT-P6-E1-T3 — Service `split`: validate the new name, mint the new speaker, rewrite the moved
  recordings scoped to the new speaker's appearances.
- PT-P6-E1-T4 — Service `delist` and `undelist`: drop the label (solo → `Unrecognized`) and restore
  it; reject delisting the mic speaker (`"You"`).
- PT-P6-E1-T5 — Service `unmerge` / `unsplit` (the library emits the cause; the service emits the
  rewrite effects) and `delete` / `undelete` (no rewrite).
- PT-P6-E1-T6 — Refactor `SpeakerEditorViewModel` to delegate to the service; point its
  `validateName` at the shared rule; the existing editor suite stays green (parity) and the
  `SpeakerEditService` suite is green.
