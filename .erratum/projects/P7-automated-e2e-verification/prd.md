# PT-P7 · Automated End-to-End Verification — Project PRD

**Status:** Frozen · **Opened:** 2026-07-01 · **Closed:** 2026-07-28 (close-out reconciled:
PT-R126–PT-R134 minted, PT-C24 minted)

## Scope

PulsarTrace has strong granular coverage — unit suites, pipeline suites over fixture audio, IPC
integration, device-gated capture tests — but nothing exercises the shipped application end to end.
The menubar app (PT-C16) is deliberately logic-free and is verified only by the manual smoke
checklist (PT-R69), which is exactly where small UI regressions have slipped through: a control that
stops working is invisible to every automated tier we have. This project builds the missing
end-to-end verification: a deterministic UI-driven test suite (the macOS analog of browser E2E
tests), an app-level real-audio smoke, and a runbook for an AI agent to perform the manual
verification a human does today.

Two testability seams make the UI suite possible and safe. First, an **isolated app state**
override: environment variables redirect every piece of mutable state the app touches — settings,
speaker library, events, logs, MCP token, default output folder — into a caller-supplied root, so a
test-launched instance can run beside the daily instance without reading or writing any of its
state. Second, an **app-reachable fixture capture mode**: with designated environment variables set,
a recording started from the UI runs the entire real flow — orchestrator, engine subprocess,
`live.md`, refinement, `final.md`, paired events — but the engine consumes committed fixture WAVs
through the existing `AudioFrameSource` fixture path instead of device capture. No devices, no TCC
prompts, full determinism. The engine already accepts fixtures for both streams in live mode; the
seam is confined to the app's record plan. On top of the seams, every driven UI surface gains a
stable accessibility identifier so tests address elements structurally, never by display text.

The deterministic suite itself is XCUITest, hosted by a generated wrapper project: SwiftPM cannot
declare a UI-test bundle, so a committed XcodeGen spec generates a disposable `.xcodeproj` (already
gitignored) whose app target compiles the same menubar sources against the same package libraries.
The suite's non-negotiable floor is breadth: launch the app on an isolated, pre-seeded home and open
every idle-reachable surface — menubar panel, Recordings, Speakers, and Settings panes — verifying
the seeded data actually renders. Deeper flows build on that floor: a full record → stop → refine
pass over fixture capture with artifact and event assertions (including the live-transcript window,
whose only entry point exists while recording — PT-P7-D8), settings persistence across relaunch, and
the speaker rename / merge / undo flows run against pre-seeded library and recording state.

Verification splits across three hosts by what each can carry. **Hosted CI** (a greenfield GitHub
Actions workflow, the repo has none today) runs the audio-independent tiers — build, the
deterministic narrow suites, and the UI suite in fixture mode — on Apple-silicon macOS runners, with
model bundles cached between runs; a non-gating probe job records what the runner VMs actually
support (audio devices, virtual-driver install, Neural Engine availability) so promoting an audio
tier to CI is a data-driven follow-up, never an assumption. **The dev host** additionally runs a new
standalone real-audio smoke script that plays a committed voice sample through BlackHole into the
real capture path and checks the refined transcript against its committed reference — the existing
`scripts/audio-loopback-check.sh` is preserved unchanged. **Agent-driven verification** is a
documented runbook: an AI agent drives the built app through the accessibility layer, walks the UI
items of the smoke checklist, and cross-checks every action against ground truth — the transcript
artifacts, the events log, and the MCP surface (PT-C22) — producing a written report. It is an
advisory pre-release aid, not a merge gate.

The manual smoke checklist stays authoritative: automation shrinks the list a human must walk, it
does not replace it, and items the suite covers are marked as such in `docs/release-smoke-test.md`.
The project introduces one new component — the end-to-end verification harness (wrapper spec, UI
suite, seeding helpers, CI workflow, smoke script, runbook), described narratively until its
component ID is minted at close-out — and touches the Menubar Application (PT-C16), the Audio Source
Layer (PT-C1, fixture path reuse), the Capture Daemon (PT-C15, bypassed in fixture mode), and the
Command-Line Interface (PT-C9, exercised by the audio smoke).

Out of scope: a signed/notarized app bundle (the unsigned dev bundle from `scripts/make-dev-app.sh`
is sufficient for local and CI automation); Appium or any WebDriver stack; screenshot-driven
computer-use automation as a gate anywhere; real-audio capture as a hosted-CI gate (the probe job
only gathers facts); new audio assets (the committed fixtures and samples suffice, with speaker
flows running on pre-seeded state); and any change to the three public API surfaces or to shipped
runtime behavior when the new environment variables are absent.

## Project Requirements

Each requirement carries a **type** (functional / technical / constraint) and a **change-type**
against the product layer (Introduce / Supersede(target) / Retire(target)). Every requirement in
this project is an **Introduce**; the product requirement numbers are minted at project close-out
(from `PT-R126` upward, derived max-plus-one over the matrix at that time) and reconciled into
`product/` then — nothing in the product layer moves while the project is open.

### PT-P7-R1 · Technical · Introduce — Environment-driven isolated app state

The menubar app honors environment overrides that redirect all mutable state to caller-supplied
locations: `PULSARTRACE_HOME` re-roots every `AppPaths` location (application support with events,
speaker library, and MCP token; logs; caches) and the default output folder root, and
`PULSARTRACE_DEFAULTS_SUITE` substitutes the `UserDefaults` suite that backs settings. A separate
`PULSARTRACE_MODELS_DIR` points the model store at an existing cache so isolated runs need not
re-download model bundles. The engine subprocesses a test-launched app spawns inherit the same
isolation. With none of the variables set, behavior is byte-identical to today.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* with the overrides
set, a full app session (launch, record via fixture mode, refine, speaker edit) reads and writes
nothing outside the supplied roots except the explicitly shared models directory; with them unset,
all paths resolve exactly as before.

### PT-P7-R2 · Technical · Introduce — App-reachable fixture capture mode

With `PULSARTRACE_MIC_FIXTURE` (and optionally `PULSARTRACE_SYSTEM_FIXTURE`) set to committed
fixture WAVs, a recording started from the app UI runs the full production flow — record
orchestrator, engine subprocess in live mode, `live.md` streaming, stop, refinement queue,
`final.md`, paired events — with the engine consuming the fixture WAVs in realtime pacing through
its existing fixture source, and no capture daemon spawned. The mode requires no microphone or
screen-recording permission and triggers no TCC prompt. One operational log line records that a
recording ran from fixtures. With the variables unset, the device capture path is unchanged.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* on a host with no
capture permissions granted, a UI-started recording with the variables set produces a `live.md` that
grows during the session and a `final.md` containing the fixture's expected keywords, with the same
event sequence as a device recording; no `pulsartrace-capture` process is launched; with the
variables unset, recording spawns the capture daemon exactly as today.

### PT-P7-R3 · Technical · Introduce — Stable accessibility identifiers on every driven surface

Every UI element the end-to-end suite drives carries a stable `accessibilityIdentifier` under one
documented naming convention: the menubar panel and its controls, the main window's sidebar and its
Recordings / Speakers / Settings panes with their interactive controls, the live-transcript window,
and the confirmation sheets and undo toasts in the speaker flows. Tests locate elements by
identifier only — display text and localization changes never break element lookup.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* the identifier
convention is documented; the UI suite contains no element lookup by display text; renaming a
control's label breaks no test.

### PT-P7-R4 · Functional · Introduce — Deterministic UI end-to-end suite

An XCUITest suite drives the real app bundle end to end, runnable locally with one command. Its
floor — the gate every run must clear before deeper flows count — is breadth over every
idle-reachable surface: the app launches against an isolated, pre-seeded home (settings, speaker
library, recording folders with refined transcripts), and the suite opens the menubar panel and each
main-window pane, verifying the seeded data renders in each. The live-transcript window — a
recording-only affordance, unreachable when idle — is verified mid-recording by the record flow
(PT-P7-D8). On that floor sit the deep flows: record → stop → refine over fixture capture asserting
on `live.md` growth, `final.md` content, and the paired events; settings persistence across an app
relaunch; and speaker rename, merge, and undo against the seeded state, asserting the retroactive
`final.md` rewrite. Checklist items the suite covers are marked in `docs/release-smoke-test.md`.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* one command runs the
suite green on a dev host; the floor scenarios open every idle-reachable surface and assert seeded
content; the record flow asserts transcript artifacts, event pairing, and the live-transcript
window; the speaker flows assert the rewrite; covered items are marked in the smoke checklist.

### PT-P7-R5 · Technical · Introduce — Generated wrapper project hosts the UI suite

The UI suite is hosted by an Xcode project generated on demand from a committed XcodeGen spec; the
generated `.xcodeproj` stays gitignored, SwiftPM remains the sole build system for every shipped
product, and the wrapper exists only to compile the menubar app into a testable bundle and host the
UI-test target. One committed script regenerates the project and runs the suite.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* no `.xcodeproj` is
committed; from a clean checkout with the documented tools installed, the script generates the
project and runs the suite; `swift build` and all `swift test` filters are unaffected by the
wrapper's existence.

### PT-P7-R6 · Functional · Introduce — Continuous integration on hosted macOS runners

A GitHub Actions workflow runs on hosted Apple-silicon macOS runners on pull requests: it builds the
package, runs the deterministic audio-independent test filters, and runs the UI end-to-end suite in
fixture capture mode. Model bundles are cached across runs. No gating step depends on audio
hardware, virtual audio drivers, or capture permissions. A separate non-gating probe job records the
runner's audio and Neural Engine reality — device enumeration, virtual-driver install viability,
CoreML compute-unit availability — as workflow output for future tiering decisions. On UI-suite
failure the workflow uploads the result bundle and screenshots.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* the workflow is green
on a PR from a clean cache and faster on a warm one; the UI job publishes failure artifacts; the
probe job cannot fail the workflow.

### PT-P7-R7 · Functional · Introduce — Standalone app-level real-audio smoke script

A new standalone script drives one real-capture end-to-end run on a configured dev host: it selects
BlackHole as the input device, plays a committed voice sample into it, records through the shipped
record path, and asserts the refined transcript against the sample's committed reference. The
existing `scripts/audio-loopback-check.sh` is preserved unchanged. The script is a documented
dev-host tool, not a CI gate.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* on a host set up per
`docs/development.md`, the script exits zero and prints the transcript match;
`audio-loopback-check.sh` is byte-identical to before the project.

### PT-P7-R8 · Functional · Introduce — Agent-driven verification runbook

A documented, repeatable runbook lets an AI agent verify the built app the way a human smoke-tester
does: drive the real UI through the accessibility layer, walk the UI items of the smoke checklist,
and cross-check every action against ground truth — transcript artifacts, the events log, and the
MCP surface — producing a written per-item pass/fail report. The runbook states its isolation
preconditions (isolated home via PT-P7-R1, daily instance quit) and is an advisory pre-release aid,
never a merge gate.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* following the runbook
on a dev host, an agent completes the walk and produces the report without touching the daily
instance's state.

### PT-P7-R9 · Constraint · Introduce — End-to-end runs never touch daily state

No automated end-to-end tier — UI suite, CI job, audio smoke, agent runbook — reads or mutates the
real user's app state: settings suite, speaker library, events log, MCP token or port, documents
output, or global hotkey registration. Test instances run from isolated roots with the MCP server
disabled and no hotkey configured unless a scenario explicitly seeds otherwise onto its own isolated
state. The only permitted sharing is the read-only model cache, explicitly opted into via
`PULSARTRACE_MODELS_DIR`.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* a full suite run on a
machine with live daily state leaves every daily-state path untouched (verified by modification-time
comparison in at least one test); seeded settings carry no hotkey and MCP off by default.
