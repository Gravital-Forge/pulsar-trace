# PT-P7-E2 · UI Harness & Floor Suite — Completion Record

**Status:** Frozen · **Closed:** 2026-07-03

## What was built

The UI end-to-end harness stands and the floor gate runs green on the dev host: full suite = launch
smoke + four floor tests, 0 failures (~50 s warm). Twelve commits (`cdd4c78..56ab87a`), each task
implemented by a dispatched subagent and passed through two-stage review, plus a final epic-level
pass (verdict READY).

- **`A11yID`** (`Sources/PulsarTraceMenuBar/A11yID.swift`) — the single identifier registry
  (`pt.<surface>.<element>`, `row(_:)` helpers suffix stable ids: recording folder basename,
  `spk_<ulid>`). Lives in the library so views and the UI-test bundle share compile-checked
  constants. The panel's `menuButton` helper takes a **required** `identifier:` parameter — a new
  panel row cannot compile without minting a constant first.
- **Attachments** across `PulsarTraceMacApp` (status item), `MenuBarMenuView` (panel container
  promoted with `.accessibilityElement(children: .contain)`, every row), `MainWindowView` (sidebar
  keyed on section case), `RecordingsSplitView`, `SpeakerEditorView` (incl. merge submenu targets,
  confirmation button, promoted undo toast), `SettingsView` (nine controls), `RecordToolbarButton`
  (window-scoped id, distinct from the panel toggle), `LiveTranscriptView` (promoted window root +
  list). AX-only; zero behavior change with or without the E2E variables.
- **Wrapper harness** — `Package.swift` gains `PulsarTraceMCP` + `PulsarTraceCapture` library
  products; committed `project.yml` (XcodeGen) generates the gitignored
  `PulsarTraceUIHarness.xcodeproj`: an app target compiling `Sources/pulsartrace-mac` against the
  four package products (harness bundle id `com.gravitalforge.PulsarTrace.uiharness`, ad-hoc signed,
  LSUIElement) and a `bundle.ui-testing` target. `scripts/run-ui-tests.sh` = `swift build` →
  `xcodegen generate` → `xcodebuild test`, args passing through.
- **`SeededHome`** — isolated home + unique defaults suite (safe PT-P7-R9 defaults pinned: no hotkey
  key, MCP off) + speaker library seeded through the real `SpeakerLibrary` API (Alice 2 appearances,
  Bob, Carol; orthogonal basis centroids) + two refined recording folders with
  `final.md`/`metadata.json` naming the seeded speakers by library id. Cleans up on failed `make()`
  (the defaults plist would otherwise leak forever).
- **`FloorTests`** — the user-set gate: on the seeded home, the menubar panel and the Recordings /
  Speakers / Settings panes open with content-bearing assertions (both folder rows by basename, all
  three speakers by `spk_` id showing names, settings controls incl. the hotkey recorder, the seeded
  output folder by seed-unique needle); daily-state mtimes (two real directories hard, the
  production plist advisory) verified unchanged, running even on skip.
- **Docs** — `docs/development.md` "UI end-to-end tests" section.

## Deltas from the spec

- **Floor scope (PT-P7-D8, user decision 2026-07-03):** the live-transcript window is asserted by
  the PT-P7-E3 record flow, not the floor — its only entry point is the panel row rendered solely
  while recording; an idle floor cannot reach it without models and a fixture session, and the
  hosted-CI floor tier must stay model-free. PRD, E2/E3 specs, and E3-T1 were reconciled in the same
  change (`56ab87a`).
- **Identifier renames vs the T1 plan:** `openMainWindow` → `openRecordings` (destination-named like
  its siblings), nested enum `Menubar` → `MenuBar`; five extra panel constants minted under the
  mint-first rule (`openSpeakers`, `openSettings`, `recoverTranscript`, `dismiss`, `quit`) plus
  `Speakers.mergeTarget(_:)` (merge is a per-target submenu, not a single button).
- **`GENERATE_INFOPLIST_FILE: YES`** added to the UI-test target (`470a250`) — test bundles have no
  `info:` block and signing otherwise fails; found on the first real `xcodebuild` run.
- **Floor navigation** uses the panel's per-section openers (sidebar `Label`s are not buttons), and
  `openPanel()` carries an explicit `XCTSkip` gate for sessions where macOS cannot place the status
  item on-screen (exists-but-unhittable only; a missing identifier still fails red).
- Review-driven hardening (`ef- style`, `dc00af1`): nil-safe teardown, seed cleanup ordered before
  the mtime assertions, seed-unique output-folder needle, launch smoke migrated to `A11yID` with the
  firstMatch fallback removed.

## Empirical findings worth keeping

- `A11yID.statusItem` on the `MenuBarExtra` label **does** surface on `app.statusItems` directly on
  macOS 15/26-era systems — the planning-time ~50% uncertainty is resolved; no fallback needed.
- The hotkey recorder (`NSViewRepresentable`) identifier surfaces fine; none of the flagged AX
  bridge hazards materialized in the floor's coverage. Context-menu items and the confirmation
  dialog remain empirically unverified until E3's speaker flows.
- A menu-bar manager (Ice) hides unknown status items by parking them off-screen (x ≈ −7000, not
  hittable while still existing in the AX tree). One-time remedy on a managed host: launch the
  harness app once and promote its icon; Ice remembers the `.uiharness` identity. Recorded for the
  E6 runbook preconditions.
- Dev-host prerequisite: after an Xcode update, `sudo xcodebuild -runFirstLaunch` may be needed
  before `xcodebuild test` works (stale `DVTDownloads` private framework).

## Known residuals (for later epics)

- The two-directory mtime check is a tripwire, not proof — nested-file writes don't bump a parent
  directory mtime; PT-P7-R1 re-rooting is the real guarantee (epic review note, LOW).
- The panel floor assertion is existence-only on the status line; asserting the "Ready" text would
  make it content-bearing (LOW).
- E3-T1's snippet still shows a `firstMatch` fallback and raw ids — implementers must use the
  FloorTests `openPanel()` idiom and `A11yID` constants (task note added).
- `project.yml`'s app target must mirror `pulsartrace-mac`'s product dependencies; a new dependency
  breaks the harness loudly at link time.

## Requirements satisfied

- **PT-P7-R3** (stable accessibility identifiers) — `A11yID.swift` + the attachment sweep across the
  seven view files; convention documented in the registry header.
- **PT-P7-R5** (generated wrapper hosts the suite) — `project.yml`, `scripts/run-ui-tests.sh`,
  `Package.swift` products, `LaunchSmokeTests`; no `.xcodeproj` or generated plist committed;
  SwiftPM suites unaffected (UnitTests 399/399, MenuBarTests 137/137 at close).
- **PT-P7-R4 (floor half)** — `SeededHome` + `FloorTests` (deep flows are E3).
- **PT-P7-R9 (verification half)** — the daily-state mtime check + safe seeded defaults; the
  constraint's isolation substrate is E1's.

Code links carry `// PT-P7-R3`, `// PT-P7-R4`, `// PT-P7-R5`, `// PT-P7-R9`.

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Mint** product requirements for PT-P7-R3, PT-P7-R5, and (once E3 completes the deep flows)
  PT-P7-R4 and PT-P7-R9 (all *Introduce*, from `PT-R126` upward per the PRD numbering note).
- **Architecture:** the E2E verification harness component (provisional in the PRD) owns
  `project.yml`, `UITests/`, `scripts/run-ui-tests.sh`, and the `A11yID` registry; the Menubar
  Application (PT-C16) description gains the identifier convention pointer.
- **Traceability:** write-once rows; `implemented_by` the files above.
- **Reference sweep:** re-point `// PT-P7-R3/R4/R5/R9` code links to the minted product ids.
