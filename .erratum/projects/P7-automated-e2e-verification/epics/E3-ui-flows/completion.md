# PT-P7-E3 · UI End-to-End Flows — Completion Record

**Status:** Frozen · **Closed:** 2026-07-04

## What was built

The deep-flow half of PT-P7-R4 runs green on the dev host: full suite = launch smoke + four floor
tests + record flow + settings persistence + three speaker-flow tests — **10 executed, 0 failures, 0
skipped, ~140 s warm**. Sixteen commits (`e720707..5e654ab`), each task through two-stage review
with fix rounds, a final epic-level pass, and one post-review empirical correction. SwiftPM parity
at close: MenuBarTests 139/139.

- **`RecordFlowTests`** — a UI-started fixture recording drives the real orchestrator → engine →
  `live.md` → refinement → `final.md` (PT-P7-R2 proven end-to-end from the UI); asserts the
  live-transcript window mid-recording through its recording-only panel row (PT-P7-D8), `live.md`
  growth with terminal-state-aware probes (refinement *moves* `live.md` → `.live.md.bak` at
  final-write), both transcript markers, an utterance line, non-empty `metadata.json`, and the
  causal event order `live_md_started` → `refinement_started` → `refinement_completed` (strings
  pinned from the `Event.swift` registry, which PT-C6 delegates exact names to). A model-cache
  preflight skips explicitly when the shared cache is empty.
- **`SettingsPersistenceTests`** — system-audio toggle off → terminate → relaunch on the same seeded
  suite → still off; seeded output folder still renders (seed-unique needle).
- **`SpeakerFlowTests`** — rename Alice→Alicia via the context menu (double-click does not arm under
  XCUITest) rewrites both seeded `final.md` files, leaves exact `final.md.bak` siblings, and logs
  `speaker_renamed` before exactly its two `final_md_rewritten` events; merge Carol→Alice via the
  Merge With submenu asserts the confirmation (including the rewrite count read from the sheet's
  message), the disk rewrite, `speaker_merged` before its rewrite event, and the undo round-trip
  restoring library and transcript with `speaker_unmerged` cause-before-effect.
- **Shared helpers consolidated** — `PanelDriver.swift` (`openPanel`, `openMainWindow`,
  `fieldShows`, `rowShowsName`/`assertRowShowsName`) and `ArtifactProbes.swift` (`poll` with
  observed-state timeouts, `eventTypes`, `size`, `newestFolder`, `preserveSeedDiagnostics` —
  failure-time seed-home evidence for CI artifact needs).
- **Product fixes shipped from findings (PT-P7-D9):** the merge undo toast wired in
  `SpeakerEditorViewModel.merge` mirroring delete/delist (PT-R32b; the smoke checklist documents the
  toast), and `withRewrite` now returns the op verdict captured before `reload()` clears `lastError`
  — all three destructive flows gate their toast on it, failed edits keep their error visible. Unit
  tests `mergeUndoToastRoundTrip` and `mergeFailureShowsNoToastAndSurfacesError` shipped in the same
  commits.
- **Operational tooling (PT-P7-D10):** `scripts/start-ui-session.sh` (the automation-mode
  authorization ceremony) and per-run tee'd logs + legible failure hints in
  `scripts/run-ui-tests.sh`; `docs/development.md` documents the dev-session procedure.
- **`docs/release-smoke-test.md`** — six items marked `*(automated: …)*` with honest partial-
  coverage qualifiers (mic/model persistence, progress-bar/list-pickup, spinner, and auto-dismiss
  timing stay manual); intro note explains the marker.

## Deltas from the spec

- T4's "one test method" became two methods plus a shared driver: the merge-rewrite AC was delivered
  green while the undo AC was blocked by the missing product toast, so the round-trip shipped as an
  explicitly-gated test and was un-gated in the same epic once the toast landed (PT-P7-D9). Final
  state has no gate.
- The task snippets' raw identifier strings, `statusItems.firstMatch` fallback, and
  `pt.menubar.openMainWindow`/sidebar-click navigation were all corrected per the E2 completion
  record: `A11yID` constants only, shared `openPanel`/`openMainWindow`, `openRecordings`-style
  per-section openers.
- The rename interaction is the context menu (`A11yID.Speakers.renameButton`, minted this epic), not
  the skeleton's row-click-then-type: the double-click gesture loses the race to the List's native
  click handling under XCUITest.
- The events log is read via a poll-until-flushed snapshot, never a single read:
  `SpeakerEditService` appends events *after* the disk rewrite completes, so disk state does not
  imply log state.

## Empirical findings worth keeping

- **The XCUITest runner has a containerized home.** `homeDirectoryForCurrentUser` in test code
  resolves to the xctrunner container, so the original `PULSARTRACE_MODELS_DIR` derivation pointed
  at a nonexistent container path and the engine silently downloaded a duplicate ~1.1 GB model set
  into that purgeable cache per cold run — the source of the day's 180 s+ "flaky" record runs
  (mid-download timeouts), two disk-writes diagnostic reports, and, once macOS purged it, a
  wrongly-firing cache preflight. Fixed by handing the real path through xcodebuild's `TEST_RUNNER_`
  env passthrough in `run-ui-tests.sh`; in-test fallback goes through `homeDirectory(forUser:)`
  (Open Directory, container-immune).
- **macOS Automation Mode** is enabled per test session by `testmanagerd` via
  `automationmode-writer` and sometimes demands the user's password; the grant lasts for the login
  session and is invalidated by screen lock (strongly evidenced; the unanswered prompt stalls the
  automation session so the next full-tree AX query never settles and the runner is killed ~60 s
  in). No `authd` right exists to pre-grant it selectively. Engineered per PT-P7-D10; hosted CI
  images pre-authorize, so this is a dev-desktop concern only.
- **AX bridge results (macOS 26.5):** SwiftUI `.contextMenu` button identifiers DO propagate to AX
  menu items (`renameButton`, `mergeButton`, `mergeTarget(_:)` all located directly);
  `confirmationDialog` surfaces as an AX **Sheet** whose message text lives in a `StaticText`'s
  **`value`** with an empty `label` (label-based predicates cannot match it); the undo-toast ids
  work as attached. The rename `TextField`'s id was shadowed by the row-level identifier — fixed
  with a conditional, identifier-only attachment in `SpeakerEditorView`.
- A full-disk host reproduces the automation-session stall symptoms; the suite's own result bundles
  (6.6 GB accumulated in one day under `.build/ui-test-results/`) were a main consumer. Retired
  whisper.cpp-era `ggml-*.bin` files (3.2 GB) in the model cache are safe to delete.

## Known residuals (for later epics / follow-ups)

- **Split flow lacks the undo toast** — the same gap merge had (`split` never calls `showToast`;
  `unsplit` GUI-unreachable), deliberately left per PT-P7-D9 because no E3 test covers split. The
  smoke checklist's "split, then unsplit" item stays manual until wired + tested.
- The merge dialog's ~8 s auto-dismiss timing and the rename toolbar spinner remain manual checks
  (markers say so).
- PT-P7-E4 (CI): runners pre-run `automationmodetool enable-automationmode-without-authentication`;
  the workflow should upload `.build/ui-test-results/<ts>.{log,xcresult}` and any
  `.build/ui-test-diagnostics/` capture on failure. Result bundles grow ~200 MB/run — prune or
  retain narrowly.
- PT-P7-E6 (runbook) preconditions to carry: unlocked interactive session, automation-mode
  authorization via `start-ui-session.sh` after any screen lock, Ice status-item promotion for the
  `.uiharness` bundle id, adequate free disk.
- `scripts/start-ui-session.sh` is not in the agent Bash allowlist (user's call — the ceremony needs
  a human for the password anyway).

## Requirements satisfied

- **PT-P7-R4 (deep-flow half)** — `RecordFlowTests`, `SettingsPersistenceTests`, `SpeakerFlowTests`,
  and the checklist markers (the floor half closed with PT-P7-E2).
- **PT-P7-R2 (acceptance evidence)** — the record flow is the UI-started proof of the fixture
  capture mode built in PT-P7-E1: full production flow, no capture daemon, deterministic.
- **PT-P7-R9** — the model-cache share now genuinely points at the host cache (the containerized
  runner had silently defeated it); isolation held throughout (all asserts on seed-home paths).
- **PT-R32b (product)** — the merge undo toast + failure-gate fixes carry `// PT-R32b` links.

Code links carry `// PT-P7-R4` (test files, scripts) and `// PT-R32b` (view-model fix).

## To flow into the product layer

At project close-out, in addition to PT-P7-E2's list: PT-P7-R4's mint covers the full suite (floor +
flows); the traceability rows' `implemented_by` add the three flow suites, the shared helper files,
and `scripts/start-ui-session.sh`; PT-R32b's existing matrix row gains the view-model fix in
`implemented_by` (no mint — existing requirement, satisfied more completely).
