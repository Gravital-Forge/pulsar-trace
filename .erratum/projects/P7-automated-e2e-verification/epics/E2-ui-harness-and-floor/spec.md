# PT-P7-E2 · UI Harness & Floor Suite — Specification

**Status:** Frozen · **Opened:** 2026-07-02 · **Closed:** 2026-07-03

## Intent

Implements PT-P7-R3, PT-P7-R5, and the floor half of PT-P7-R4 (plus the untouched-daily-state check
of PT-P7-R9); touches the Menubar Application (PT-C16). One shared `A11yID` constants file in
`PulsarTraceMenuBar` defines the identifier convention and every identifier both the views and the
tests use; the views in `Sources/pulsartrace-mac` attach them; an XcodeGen spec generates the
disposable wrapper project (an app target compiling the same menubar sources, ad-hoc signed with its
own harness bundle id, plus a `bundle.ui-testing` target under repo-root `UITests/`); a committed
script regenerates and runs it. A `SeededHome` helper builds the isolated, pre-seeded state
(settings suite, speaker library via the real `SpeakerLibrary` API, refined recording folders) that
the floor suite launches against. The floor suite is the user-set gate: open every surface, verify
the seeded data renders, and prove the daily instance's state untouched.

## Acceptance criteria

- `A11yID` is the single source of identifiers (`pt.<surface>.<element>`, stable row-suffix helpers
  for dynamic lists); no UI test locates an element by display text (PT-P7-R3).
- Every surface the floor suite drives carries its identifier: status item, menubar panel (record
  toggle, open-main-window, open-live-transcript), main-window sidebar entries, the Recordings /
  Speakers / Settings panes' interactive controls, and the live-transcript window.
- `bash scripts/run-ui-tests.sh` on a dev host with Xcode + XcodeGen: builds the package binaries,
  generates `PulsarTraceUIHarness.xcodeproj` (gitignored), and runs the UI suite green; no
  `.xcodeproj` or generated plist is committed; `swift build` / `swift test` are unaffected
  (PT-P7-R5).
- The floor test launches on a `SeededHome`, opens the menubar panel and the Recordings, Speakers,
  and Settings panes, asserts seeded content in each — and asserts the real daily-state paths'
  modification times are unchanged by the run (PT-P7-R9). The live-transcript window (recording-only
  affordance) is asserted by the PT-P7-E3 record flow instead (PT-P7-D8).
- `docs/development.md` documents prerequisites and the one-command run.

## Tasks

- PT-P7-E2-T1 — `A11yID` constants + identifiers on the status item and menubar panel.
- PT-P7-E2-T2 — Identifiers across the main window, live-transcript window, and speaker sheets.
- PT-P7-E2-T3 — Package products, XcodeGen spec, `UITests/` scaffold, run script, launch smoke.
- PT-P7-E2-T4 — `SeededHome`: isolated home + settings + speaker library + refined recordings.
- PT-P7-E2-T5 — The floor suite: every surface opens, seeded data renders, daily state untouched.
- PT-P7-E2-T6 — `docs/development.md`: UI end-to-end testing section.
