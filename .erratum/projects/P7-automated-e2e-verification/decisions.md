# PT-P7 · Automated End-to-End Verification — Decision Log

**Status:** Frozen · **Closed:** 2026-07-28

The reasoning behind the end-to-end verification strategy, recorded as each choice was taken.
Append-only.

## Decisions

### PT-P7-D1 · The UI suite is XCUITest hosted by an XcodeGen-generated wrapper project

*2026-07-01*

**Decision:** The deterministic UI end-to-end suite is written in XCUITest. Because SwiftPM cannot
declare a UI-test bundle, a committed XcodeGen spec (`project.yml`) generates a disposable
`.xcodeproj` (already gitignored) containing two targets: an app target that compiles the same
`Sources/pulsartrace-mac` sources against the same package library products, and a
`bundle.ui-testing` target holding the suite under a repo-root `UITests/` directory — outside
`Tests/` so SwiftPM never sees it. One committed script regenerates the project and runs
`xcodebuild test`. Appium Mac2Driver and AppleScript/AX shell scripting were rejected as the suite's
foundation.

**Because:** XCUITest is the platform-native accessibility-tree driver with first-class menu-bar
support (`XCUIElementTypeStatusItem` and the `statusItems` query are in the shipped SDK), real
assertions, launch-environment injection (which carries the isolation and fixture variables of
PT-P7-R1/R2 directly into the app process), and result bundles with automatic failure screenshots.
GitHub's hosted macOS images pre-run
`automationmodetool enable-automationmode-without-authentication` and pre-grant Xcode Helper the
Accessibility TCC service, so the same suite runs on CI with no permission scripting. Appium Mac2
drives the same XCUITest core but adds a Node/WebDriver stack and an out-of-process server for no
additional capability at this scale. Raw AppleScript/AX scripts have no assertion framework, no
fixture lifecycle, and match elements by display text — exactly the brittleness PT-P7-R3 exists to
eliminate. XcodeGen (actively maintained) keeps the wrapper a build-time artifact: SwiftPM stays the
sole build system for shipped products, and no `.xcodeproj` is ever committed or hand-maintained.

### PT-P7-D2 · Fixture capture mode branches in the app's record plan, driven by environment variables

*2026-07-01*

**Decision:** Fixture capture mode (PT-P7-R2) is implemented where the app assembles its recording
subprocesses: with `PULSARTRACE_MIC_FIXTURE` / `PULSARTRACE_SYSTEM_FIXTURE` set, the record plan
launches the engine with its existing fixture-source arguments
(`--live --source fixture <system.wav> --mic-fixture <mic.wav>`, realtime pacing) and skips spawning
the capture daemon entirely. No new engine capability is built — the engine already runs live
sessions from paired fixtures — and no settings toggle or UI for the mode exists.

**Because:** the engine's fixture path is the already-tested, production-shipped mechanism for
hardware-free sessions (PT-R71), and `AudioFrameSource` is the single sanctioned audio boundary — so
the only genuinely missing piece is the app-side plan branch, the smallest possible seam.
Environment variables are the right trigger: they are invisible and unreachable in normal use (no
UI, no settings key, no accidental activation), they flow naturally from XCUITest's
`launchEnvironment` and from CI, and the codebase already uses this idiom for test-time redirection
(`PULSARTRACE_BIN_DIR`). A hidden settings toggle was rejected because persisted state can leak into
real sessions and would put a test-only control on a user surface; injecting a fixture source
in-process was rejected because it would bypass the real orchestrator → engine subprocess → socket
lifecycle that end-to-end tests exist to cover.

### PT-P7-D3 · Isolation is environment-driven re-rooting, with the model cache shared by explicit opt-in

*2026-07-01*

**Decision:** Test isolation (PT-P7-R1, PT-P7-R9) re-roots app state through environment variables
read at composition time: `PULSARTRACE_HOME` for every `AppPaths` root and the default output
folder, `PULSARTRACE_DEFAULTS_SUITE` for the settings suite. When `PULSARTRACE_HOME` is set,
*everything* moves — including the model store — and the harness explicitly points
`PULSARTRACE_MODELS_DIR` at the real cache when it wants to reuse downloaded models. Engine
subprocesses inherit the isolation through the orchestrator's environment pass-through.

**Because:** the app already funnels every path through `AppPaths` and every setting through one
`UserDefaults` suite, so two variables cover the entire mutable surface at the two existing choke
points — no per-path plumbing, no behavior change when unset. Full-move-by-default with explicit
cache sharing was chosen over keep-cache-shared-by-default because a surprising implicit share is
exactly how a "hermetic" test ends up touching real state; the ~1 GB re-download is opted out of
consciously, per harness, and the share is read-only in practice. A launch-argument scheme was
rejected because arguments appear in process listings and would need separate plumbing for spawned
subprocesses, while environment inherits; a config file was rejected as one more piece of mutable
state to isolate.

### PT-P7-D4 · Hosted CI runs only audio-independent tiers; audio and Neural Engine facts come from a non-gating probe

*2026-07-01*

**Decision:** The GitHub Actions workflow (PT-P7-R6) gates only on tiers with no audio dependency:
package build, the deterministic narrow `swift test` filters, and the UI suite in fixture capture
mode. Real-audio capture is never a hosted-CI gate in this project. A separate probe job — allowed
to fail, never gating — records the runner's actual capabilities: audio device enumeration,
BlackHole installability, and which CoreML compute units the VM exposes.

**Because:** the verified facts about hosted runners support exactly this split. In their favor:
they run a real logged-in Aqua session, pre-authorize UI automation and the Accessibility service,
and allow TCC database edits (SIP is disabled at image build) — so accessibility-driven UI testing
is a supported, first-class use. Against them: the images provision no audio device and no audio
tooling, and the runners are Virtualization-framework VMs, which do not expose the Apple Neural
Engine — CoreML will fall back to CPU/GPU, which fixture-mode transcription tolerates (slower, same
output) but which makes any timing- or ANE-assertion invalid on CI. Whether BlackHole-based mic
capture and ScreenCaptureKit system-audio actually work inside the VM is unverified — so instead of
betting a gate on folklore, the probe job gathers the facts and a future revision promotes audio
tiers only if the data says they hold. The real-audio smoke (PT-P7-R7) meanwhile runs where audio is
known-good: the dev host.

### PT-P7-D5 · The real-audio smoke is a new standalone script; the existing loopback check is preserved

*2026-07-01*

**Decision:** The app-level real-audio smoke (PT-P7-R7) is a new script alongside
`scripts/audio-loopback-check.sh`, which stays byte-identical. The new script exercises the shipped
record path end to end (BlackHole input → capture daemon → engine live pass → refinement →
transcript assertion against the committed reference), while the old script keeps its narrower
ffmpeg-based capture check.

**Because:** the user chose explicitly (2026-07-01) to keep the old functionality working rather
than extend it. The two scripts also answer different questions — "does audio route through this
host's loopback device" versus "does the shipped capture-to-transcript path work on real audio" —
and a combined script would couple an environment diagnostic to a product test, making both harder
to run and to interpret.

### PT-P7-D6 · Speaker-flow UI tests run against pre-seeded state, not in-test recordings

*2026-07-01*

**Decision:** The rename / merge / split / undo UI scenarios (part of PT-P7-R4) run against a
pre-seeded isolated home — a speaker library and recording folders with refined transcripts written
by a seeding helper before app launch — rather than against recordings produced inside the test via
fixture capture.

**Because:** the user chose pre-seeded state explicitly (2026-07-01). It is also the right
engineering call: the committed fixtures top out at ~30 seconds and two speakers, so an in-test
recording would give the speaker flows a thin, slow substrate — every speaker scenario would pay a
full live-plus-refine pass just to arrange state, and diarization variance would leak into what are
UI-behavior tests. Seeding writes exact, rich state (multiple speakers, multiple recordings,
merge-worthy duplicates) in milliseconds and keeps the record→refine path covered once, in its own
dedicated flow test, where its variance is the subject rather than noise.

### PT-P7-D7 · Agent verification drives the accessibility tree, cross-checks through the MCP surface, and gates nothing

*2026-07-01*

**Decision:** The agent runbook (PT-P7-R8) has the agent drive the real app through an
accessibility-tree tool (Peekaboo CLI/MCP as the reference tool; any AX-based equivalent satisfies
the runbook), not through screenshot-coordinate automation. Every UI action is verified against
ground truth the agent can read independently: `live.md` / `final.md` on disk, the events log, and
PulsarTrace's own MCP tools. The runbook requires the daily instance quit and an isolated home, and
its output is an advisory report — it gates no merge and runs in no CI.

**Because:** AX-tree driving is structural — the same property that makes XCUITest robust — while
screenshot automation on macOS 15+ additionally trips the periodic screen-capture re-confirmation,
which breaks unattended runs on the very host this layer targets. The MCP surface (PT-C22) exists
precisely so an agent can observe recordings, speakers, and events without scraping UI, so using it
as the verification channel tests two product surfaces in one pass and keeps the agent's conclusions
grounded in artifacts rather than pixels. It stays advisory because an LLM-driven walk is not
deterministic enough to gate merges — its value is breadth and judgment on the checklist items
automation cannot express (visual states, notification behavior), as a complement to the
deterministic suite, cheaper and more repeatable than a human walk. Quitting the daily instance
removes the one real ambiguity: two identical status items in one menu bar.

### PT-P7-D8 · The floor covers the idle-reachable surfaces; the live-transcript window is asserted by the record flow

*2026-07-03*

**Decision:** The PT-P7-R4 floor suite verifies the four idle-reachable surfaces — menubar panel,
Recordings, Speakers, Settings — on the seeded home. The live-transcript window is verified by the
E3 record flow, which opens it mid-recording through its real affordance and asserts it renders.
User decision 2026-07-03, made when the floor first ran against the real app.

**Because:** the live-transcript window's only entry point is the menubar panel row that
`MenuBarMenuView` renders solely while a recording is running; when idle the window is unreachable
by design, and the LSUIElement harness app has no on-screen menu bar to offer an alternative route.
Keeping the check in the floor would force the floor to run a fixture recording with the shared
model cache — making the floor model-dependent, which the hosted-CI floor tier (PT-P7-R6) must not
be. The record flow already drives a fixture recording, so asserting the window there costs one
extra click and keeps the floor fast, model-free, and honest about what "idle breadth" can reach.

### PT-P7-D9 · Product gaps the E2E suite surfaces get fixed in-branch when an epic AC depends on them

*2026-07-04*

**Decision:** When an E3 flow test exposed shipped GUI behavior contradicting the product layer —
the merge flow presented no undo toast (`SpeakerEditorViewModel.merge` never called `showToast`;
`unmerge` was reachable only from the MCP surface), contradicting PT-R32b and the smoke checklist —
the fix was made in-branch, mirroring the existing delete/delist toast pattern, with unit tests
shipped in the same commit. The same round fixed the dead success gate the pattern carried in all
three destructive flows (`reload()` clears `lastError`, so every `lastError == nil` toast gate
passed even for failed edits — a failed merge/delete/delist showed a phantom undo toast and
swallowed its error). The split flow's identical missing-toast gap is deliberately NOT fixed: no E3
test covers split, tests ship with the code that creates them, and it is recorded as a known issue
for a follow-up instead.

**Because:** the epic's acceptance criteria (undo-toast round-trip) were unreachable against the
shipped app, and the alternative — weakening the AC or gating the test indefinitely — would paper
over a real defect the verification layer exists to catch. Fixing at the source with the sibling
pattern and unit coverage is the smallest honest change; expanding to split without a test would
ship an unverified behavior change.

### PT-P7-D10 · macOS automation-mode authorization is an explicit dev-session ceremony, not a blanket grant

*2026-07-04*

**Decision:** Local UI-suite runs treat macOS Automation Mode as an engineered precondition:
`scripts/start-ui-session.sh` fronts the "XCTest is trying to Enable UI Automation" password prompt
at a chosen moment by running the launch smoke, and prints one unambiguous verdict;
`scripts/run-ui-tests.sh` logs every run to a file and, on the 60-second
`Timed out while enabling automation mode` failure, prints an actionable hint instead of a bare exit
65\. The blanket local enable (`automationmodetool enable-automationmode-without-authentication`,
which hosted CI images pre-run — PT-P7-D1) was considered and declined by the user for the dev
desktop.

**Because:** the authorization is granted per login session and empirically invalidated by screen
lock, with no `authd` right behind it to pre-grant selectively — so the choice was blanket
convenience versus machine security posture, and the user chose posture. An automation suite that
can silently stall on a security dialog must instead fail fast and legibly, and the recurring prompt
is an operating fact of the platform that the runbook (PT-P7-R8) and CI notes (PT-P7-R6) carry
rather than a nuisance to click through.
