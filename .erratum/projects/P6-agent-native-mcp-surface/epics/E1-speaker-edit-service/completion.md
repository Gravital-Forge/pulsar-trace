# PT-P6-E1 · Speaker Edit Service — Completion Record

**Status:** Frozen · **Closed:** 2026-06-29

## What was built

The speaker-edit orchestration is now a reusable `PulsarTraceEngine` actor,
`SpeakerEditService`, injected with the `SpeakerLibrary`, an optional `EventWriter`, and a
`FinalMarkdownRewriter`. It exposes all nine operations — `rename`, `merge`, `split`, `unmerge`,
`unsplit`, `delist`, `undelist`, `delete`, `undelete` — plus the shared `static validateName(_:)`
rule (rejects empty/whitespace and the Markdown-significant characters `+ * \``) and the
`EditResult` / `EditError` value types. Each rewriting operation takes the current output-folder
roots as a per-call parameter, so the roots can change between edits.

Each rewriting op follows one causal contract: mutate the library with its event suppressed
(`suppressEvent: true`), run the rewriter over the affected appearances, then emit the `speaker_*`
cause event before one `final_md_rewritten` effect per rewritten recording. The two reversal ops
`unmerge` / `unsplit` are the exception the spec called out — the library emits its own
`speaker_unmerged` / `speaker_unsplit` cause, so the service emits only the rewrite effects and
never a duplicate cause; `unsplit` reads the appearances *before* the library call, while the rows
still resolve under the new id. `delete` / `undelete` are state-only and perform no rewrite. The
microphone speaker (`"You"`) delist rejection and the unchanged-name `rename` no-op live in the
service, so the MCP and CLI callers inherit them.

`SpeakerEditorViewModel` was refactored to delegate: it holds a `SpeakerEditService` constructed in
`init` with the same `library` + `events` it already owns, and every mutating method is now a single
`service.<op>(…)` call inside the existing `withRewrite { }` wrapper. The view model keeps all of its
UI concerns (`isRewriting`, `lastError`, the undo toasts, `reload`, and the cheap pre-`withRewrite`
checks and messages); `validateName` delegates to the shared rule. The inlined rewriter calls, the
view model's own `emitRewriteEvents`, the per-op event `append`s, and an orphaned private
`EditorError` enum were all removed (a 163-line deletion against 28 lines added).

Coverage: a new `SpeakerEditServiceTests` suite (`Tests/PipelineTests/`) drives all nine operations
directly — the path the MCP and CLI callers take when they bypass the view model — over hand-built
fixture recording folders, asserting the file rewrite, the events emitted, and the cause-before-
effect log order (11 tests). The pre-existing `SpeakerEditorViewModelTests` suite (15 tests) is the
parity guard and passes unchanged.

## Deltas from the spec

- **Test fixture wiring contract surfaced.** The `unmergeEmitsSingleCause` test as planned built the
  `SpeakerLibrary` without an `EventWriter`, so the library's own `speaker_unmerged` event never
  reached the log. The fixture was corrected to construct the library *with* the shared `EventWriter`
  — matching production and the existing view-model tests. This makes explicit a real invariant for
  later epics: any caller of `unmerge` / `unsplit` / `delete` / `undelete` must build the
  `SpeakerLibrary` with the same `EventWriter` the service uses, or the library-emitted cause events
  go unlogged. The menubar already wires them together; the MCP composition root (PT-P6-E5) must too,
  which also satisfies the single-writer requirement (PT-P6-D1).
- **Mixed error surface, by design.** `rename` and `delist` pre-check the speaker and throw
  `EditError.speakerNotFound`; the other ops surface the library's own `LibraryError` directly (no
  redundant pre-check), preserving the prior view-model behaviour. The MCP write tools (PT-P6-E4)
  wrap any thrown `Error` into a tool error, so the surface is uniform to a caller.
- **Class doc comment updated** on `SpeakerEditorViewModel` to describe the delegation rather than
  the now-removed inline orchestration. No other deltas; observable behaviour is unchanged.

## Requirements satisfied

- **PT-P6-R9** (shared speaker-edit orchestration service) —
  `Sources/PulsarTraceEngine/SpeakerLibrary/SpeakerEditService.swift` (the actor, its nine ops,
  `validateName`, `emitRewriteEvents`, `EditResult` / `EditError`); the delegation in
  `Sources/PulsarTraceMenuBar/SpeakerEditorViewModel.swift` (the `service` property + every mutating
  method). Tests: `Tests/PipelineTests/SpeakerEditServiceTests.swift`, with
  `Tests/MenuBarTests/SpeakerEditorViewModelTests.swift` as the parity guard. Code links carry
  `// PT-P6-R9`.

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Mint** the Speaker Edit Service component (provisional in the PRD; its `PT-C` id derived
  max-plus-one at close-out) for the `SpeakerEditService` actor, and the product requirement for
  PT-P6-R9 (an *Introduce*, from `PT-R115` upward) for the shared orchestration.
- **Architecture:** note the reshape of the Speaker Library (PT-C5) and the Refinement Pipeline's
  retroactive rewriter (PT-C4) — both are now driven through the shared service — and the refactor of
  the Menubar Application (PT-C16) to delegate speaker edits. The CLI (PT-C9) adopts the service in
  PT-P6-E6.
- **Traceability:** a write-once row for the PT-P6-R9 product requirement, `implemented_by` the
  `SpeakerEditService` symbols above.
- **Reference sweep:** re-point every `// PT-P6-R9` code link to the minted product requirement id.
