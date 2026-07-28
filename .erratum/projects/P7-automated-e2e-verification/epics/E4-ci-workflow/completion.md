# PT-P7-E4 · CI Workflow — Completion Record

**Status:** Frozen · **Closed:** 2026-07-27

## What was built

`.github/workflows/ci.yml` (PT-P7-R6, PT-P7-D4) — the repo's first CI: four jobs on hosted
Apple-silicon runners, triggered on `pull_request`, `push` to `main`, and `workflow_dispatch`, with
superseded-run cancellation. Verified live on PR #18 across five runs; the final run
(30310108440) is green on all four jobs. Five commits (`84692b4..6f381f3` plus the diagnostics
upload fix), plus the main-merge sync after the P6 squash landed.

- **`build-and-test`** (gating, ~10 min) — `swift build` + the nine hermetic filters, one bare
  invocation each (`UnitTests`, `IPC`, `RecordOrchestrator`, `LiveRunner`, `Speaker`, `Source`,
  `Lifecycle`, `FinalMarkdownRewriter`, `MenuBarTests`); the broad `PipelineTests` run is never
  invoked (cross-suite fd races). Model-downloading filters are deliberately absent — that cost
  lives in the cached `ui-flows` lane.
- **`ui-floor`** (gating, ~6.5–8.5 min) — the full XCUITest suite minus `RecordFlowTests` via
  `scripts/run-ui-tests.sh -skip-testing:`; uploads `.build/ui-test-results` +
  `.build/ui-test-diagnostics` on failure.
- **`ui-flows`** (gating, 90-min ceiling) — restores `~/Library/Caches/PulsarTrace/models` under
  key `pt-models-macOS-v1` (actions/cache@v6); on a cold cache primes via the `Parakeet` and
  `WhisperKitRefine` filters (doubling as CPU/GPU-fallback backend coverage), then runs
  `RecordFlowTests` only. Cold run: `Cache not found` → FluidAudio + WhisperKit downloads → flow
  green → `Cache saved`, **11 m 6 s total**. Warm runs: `Cache hit`, zero download lines, priming
  skipped, **5 m 55 s–9 m 24 s** — both far under the ~30-min demotion threshold the spec set, so
  the job stays gating with no decision needed.
- **`probe`** (non-gating, 40 s, `continue-on-error`) — the PT-P7-D4 fact-gatherer; findings below.
- README carries the workflow badge.
- **Product fix shipped from a finding (PT-P7-D9):** the menubar panel now dismisses itself when a
  nav row opens the main window (`MenuBarMenuView.open` calls `dismiss()`). Three `ui-floor` cases
  failed on the runner as `Not hittable`: the panel — which nothing ever "clicks outside" of under
  accessibility driving — lingered at {{768,32},250×184} and geometrically covered the settings
  toggle and merge menu on the runner's small display. A human's next click dismisses it as a side
  effect, so the gap was invisible on large dev-host screens; menu-like dismiss-on-pick is the
  correct product behavior regardless of the suite.

## Deltas from the spec

- **`macos-26` runners, not `macos-15`, with `DEVELOPER_DIR` pinned to Xcode 26.6.**
  macos-15's default toolchain is Xcode 16.4 / Swift 6.1.2, which rejects the
  actor-init pattern in `SpeakerLibrary.swift` (`non-sendable result type 'SQLiteDatabase' cannot
  be sent from nonisolated context`) that the project's Swift 6.3.3 accepts; macos-15's newest
  installed Xcode is 26.3. macos-26's default is Xcode 26.6 — exactly the dev-host toolchain. The
  explicit pin makes future image drift fail loudly on the version step instead of silently
  building with a different compiler.
- E3's residual anticipated the runner needing
  `automationmodetool enable-automationmode-without-authentication` — not needed: hosted images
  come pre-authorized and no automation-mode stall was observed on any run.
- The failure-artifact upload includes `.build/ui-test-diagnostics/` (the `preserveSeedDiagnostics`
  seed-home evidence) alongside the result bundles, per E3's residual note.

## Probe findings (run 30310108440, macos-26 image 20260720.0258.1)

1. **Stock audio devices exist:** "Apple Virtual Sound Device" as default input (2ch mic, 48 kHz,
   Transport: Built-in) and default output (2ch speakers), plus a "Null Audio Device" (virtual).
2. **BlackHole is viable without a reboot:** the `blackhole-2ch` 0.7.1 cask installs (installer
   requests a restart), but after `sudo killall coreaudiod` + 5 s, "BlackHole 2ch" (2-in/2-out,
   48 kHz, Virtual, Existential Audio Inc.) appears in `system_profiler SPAudioDataType`.
3. **SIP is disabled** on the runner VM.
4. **No Neural Engine:** `MLComputeDevice.allComputeDevices` = `[MLGPUComputeDevice (Apple
   Paravirtual device), MLCPUComputeDevice]`. ANE-dependent behavior can never be verified on
   hosted CI; CPU/GPU fallback is what the `ui-flows` lane exercises (and proves functional).

Implication for PT-P7-D4: a real-audio CI tier is *plausible* (virtual input device present,
BlackHole installs and registers, SIP off) — promoting one remains a project decision to be taken
on this data, not in this epic.

## Known residuals

- Result bundles are ~200 MB/run and upload only on failure with default retention; prune retention
  if failure artifacts accumulate.
- The GitHub Checks annotations API is unreadable with a fine-grained PAT (no `checks:read`
  permission exists) — agent-driven CI debugging reads job logs via
  `gh api …/actions/jobs/<id>/logs` instead.
- The local dev-host suite re-run with the panel-dismiss fix is pending (screen-locked session at
  close); CI's `ui-floor` + `ui-flows` green on macos-26 is the current evidence, and the fix is
  exercised by every future run. Re-verify locally with `scripts/run-ui-tests.sh` at next
  opportunity.

## Requirements satisfied

- **PT-P7-R6** — the workflow, its triggers, gating set, model cache (warm run downloads nothing),
  failure artifacts, non-gating probe, and README badge. `ci.yml` carries the `PT-P7-R6` /
  `PT-P7-D4` link in its header comment.
- **PT-P7-D9 (product fix)** — `MenuBarMenuView` panel dismissal, `// PT-P7-D9` link at the call.

## To flow into the product layer

At project close-out: PT-P7-R6's mint gets `implemented_by: .github/workflows/ci.yml` (+ the README
badge line); the PT-R40 (menubar dropdown) matrix row gains `MenuBarMenuView.open`'s dismiss fix in
`implemented_by`. The probe findings feed any future project that proposes promoting an audio tier
to CI (PT-P7-D4's data-driven follow-up).
