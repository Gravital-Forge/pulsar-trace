# PT-P7-E4 · CI Workflow — Specification

**Status:** Open · **Opened:** 2026-07-02

## Intent

Implements PT-P7-R6 per PT-P7-D4; pure infrastructure — no product target changes. One greenfield
GitHub Actions workflow on hosted Apple-silicon macOS runners with four jobs: `build-and-test`
(package build + the hermetic narrow filters, one bare invocation each — never the broad
`PipelineTests`), `ui-floor` (the E2 harness minus the model-dependent record flow), `ui-flows` (the
record flow with the model cache restored; CoreML falls back to CPU/GPU in the runner VM — no ANE —
so timeouts are generous and no timing is asserted), and `probe` (non-gating fact gathering: audio
devices, BlackHole install, SIP, CoreML compute devices). UI jobs upload their `.xcresult` bundles
on failure.

## Acceptance criteria

- `.github/workflows/ci.yml` triggers on pull requests, pushes to `main`, and manual dispatch;
  `build-and-test` and `ui-floor` gate every PR; `ui-flows` gates with a long timeout; `probe` can
  never fail the workflow.
- Model bundles cache under a versioned key; a warm run downloads nothing.
- On UI failure, the uploaded artifact contains the `.xcresult` (with its automatic screenshots).
- The probe job's log answers: does the VM expose any audio device, does BlackHole install and
  register after a `coreaudiod` restart, what is `csrutil status`, which `MLComputeDevice`s exist.
- README gains the workflow badge.

## Tasks

- PT-P7-E4-T1 — Workflow skeleton: build-and-test + ui-floor jobs, failure artifacts.
- PT-P7-E4-T2 — ui-flows job with the model cache.
- PT-P7-E4-T3 — Non-gating probe job + README badge.
