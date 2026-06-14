# PulsarTrace — agent instructions

A local-only macOS meeting transcription app. Source of truth: `project-docs/PRD.md`.
Status and architecture deviations: `project-docs/PLAN.md`, `project-docs/DECISIONS.md`.
Dev host + sandbox model: `project-docs/PREWORK.md`.

## Running build & tests (Claude Code Bash sandbox)

These rules let you run builds and tests **without permission prompts** in
don't-ask mode. They are easy to get wrong — read them before running:

- `swift build` / `swift test` must be run with `dangerouslyDisableSandbox:
  true` — SwiftPM compiles the manifest in a nested `sandbox-exec` the outer
  sandbox blocks. The flag is allowlisted **only** for `swift build` /
  `swift test`.
- **Run the command bare — no shell operators of any kind.** Any `|`, `;`,
  `>`, or `&&` makes the command stop matching the `Bash(swift build *)` /
  `Bash(swift test *)` allowlist entry, so in don't-ask mode it is denied.
  This includes redirects: `swift test … > log 2>&1` is denied too.
- Long output is handled for you — the harness auto-persists oversized output
  to a file and shows a preview. Read the rest with the Read tool or a
  separate bare `tail` in a follow-up call. Do not pipe or redirect to shorten
  it yourself.
- `swift run` is denied even bare — run the built binary directly:
  `.build/debug/pulsartrace …` (also with `dangerouslyDisableSandbox: true`).
- `git` and everything else run **plain, in-sandbox** — do NOT pass
  `dangerouslyDisableSandbox: true`; the flag is what gets them denied.

Example: `swift test --filter UnitTests`, run bare, with
`dangerouslyDisableSandbox: true`.

## Test posture: no failing tests, ever

Every test must either **pass** or be **explicitly gated** out of the
normal-development run (`.disabled(...)`, `.enabled(if:)`, or equivalent,
with a one-line comment naming the gate condition).

If you observe a failing test — even one you didn't touch, even one you
think is "flaky" or "env-dependent" — that is your problem the moment you
see it. Either fix the underlying cause, gate the test with an explicit
skip mechanism, or escalate to the user. Do not move on with a red suite.

"My new tests pass" is not enough. The full relevant suite must be green
or explicitly-gated after your change.

### Known limitation: `--filter PipelineTests` is broadly flaky

Running everything under `Tests/PipelineTests/` together in one command —
e.g. `swift test --filter PipelineTests` — is **known-flaky** under
cross-suite races. POSIX file descriptors, Unix domain sockets, and
subprocess slots are process-wide resources; Swift Testing's `.serialized`
trait only serializes *within* a suite, so when `Pipeline IPC integration`,
`Capture IPC integration`, `RecordOrchestrator (record, R47)`, and
`LiveRunner resilience` all run in parallel with each other, one suite's
fd churn can race another's `socket()`/`close()` and surface as `EBADF` or
a subprocess that exits non-zero because its socket disappeared. The set
of failures shifts run-to-run, which is the signature of a parallelism
race, not a deterministic regression.

This is not caused by any single change — verified pre-existing on
multiple commits. A correct fix needs a non-reentrant cross-suite async
mutex (CheckedContinuation + waiter queue, not a plain actor — actors are
reentrant across `await` suspensions and won't actually serialize).

**Until that mutex is built, verify with the narrow filters instead:**

- `swift test --filter UnitTests` — pure logic, deterministic, fast
- `swift test --filter Refinement` — covers refinement pipeline + queue
- `swift test --filter IPC` — IPC suites in isolation
- `swift test --filter RecordOrchestrator`
- `swift test --filter LiveRunner`
- `swift test --filter Streaming`
- `swift test --filter Parakeet` — live ANE backend (one-time ~0.5 GB model download)
- `swift test --filter WhisperKitRefine` — refine ANE backend (one-time ~626 MB download)
- `swift test --filter FluidVAD` — Silero-CoreML region detection
- `swift test --filter Speaker` — speaker library + reconciler
- `swift test --filter DiarizationE2E` — FluidAudio offline diarization (one-time ~21 MB model download)
- `swift test --filter Source`
- `swift test --filter Lifecycle`
- `swift test --filter FinalMarkdownRewriter`

Each of these is green on its own. If you observe a failure inside any
of them, treat it per the rule above. The broad `--filter PipelineTests`
should not block forward progress until the cross-suite mutex lands.
