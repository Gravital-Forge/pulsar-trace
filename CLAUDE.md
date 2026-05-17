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
