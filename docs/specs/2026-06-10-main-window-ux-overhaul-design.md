# Main Window UX Overhaul — Master–Detail Recordings, In-Window Live Transcript, Queue Folding

- **Status:** design approved 2026-06-10 (brainstormed; visual/IA decisions delegated to the agent by the user — "more polished, internally consistent, feels good")
- **Date:** 2026-06-10
- **Scope:** `pulsartrace-mac` (views) + `PulsarTraceMenuBar` (new view models). No engine, capture, or public-API changes (`live.md` / `final.md` / `events/*.jsonl` untouched).
- **Builds on:** `docs/specs/2026-06-10-ui-polish-plan.md` (previous polish round, implemented — transcript parser/styled rendering, friendly titles, menubar icon states, notifications, context menus, hotkey recorder).
- **Floor:** macOS 14 (`ContentUnavailableView`, `@Observable`, `symbolEffect(.pulse)` available; `.rotate` is not).

## 1. Problem

The unified window works but reads as a debug surface, not a product:

1. **Transcripts — the app's core content — open in a fixed 540×480 modal sheet.**
   No resize, no browse-while-reading, no live view of the recording in
   progress from the main window.
2. **The primary action is invisible.** Start/stop exists only in the menubar
   dropdown and the global hotkey; the main window has no record affordance.
3. **Internal machinery leaks into the UI.** A "Refinements" sidebar pane shows
   raw monospaced recording ids and queue states; users think in recordings,
   not jobs.
4. **Lists feel dead.** Single click does nothing (double-click and context
   menu only); every refined row carries a permanent green check (noise);
   recordings are a flat undifferentiated list with no search.
5. **Assorted inconsistencies:** brand heading inside the sidebar, duplicated
   in-content window headers, banners overlaying list rows, two divergent
   transcript renderers (cross-line selection broken in one of them).

## 2. Goals / Non-goals

**Goals**

- Recordings pane becomes master–detail: list left, transcript right,
  resizable split; the transcript of the selected recording — including the
  one being recorded right now — renders in the window.
- One-click record from the window toolbar on every pane; pressing it shows
  the live transcript streaming.
- Refinement status lives on recording rows; the Refinements pane is deleted.
- Day-grouped, searchable, selection-driven recordings list with
  exceptional-only status badges.
- `ContentUnavailableView` empty states with actions (the PRD's R44 epic
  explicitly asks for a quick-start CTA in the recordings empty state).
- One transcript renderer (the NSTextView-backed path) everywhere: fixes
  cross-line selection, enables find-in-transcript.
- Internal consistency sweep: Speakers list adopts the same selection model;
  banners stop covering content; duplicated headers removed.

**Non-goals**

- No activation-policy / Dock-icon / menu-bar change (locked decision D27:
  menubar-only accessory app).
- No Liquid Glass adoption, no onboarding tour (R46 stays deferred), no
  speaker "play sample" (R31 remainder), no menubar dropdown redesign beyond
  the hover-color correctness fix.
- The detached Live Transcript window (R45) is kept, not replaced — the
  in-window live detail is an addition.
- No new index database — the list stays scan-based (R44).

## 3. Information architecture

Sidebar shrinks to three sections: **Recordings, Speakers, Settings**
(`AppSection.refinements` deleted). The "PulsarTrace" text heading above the
sidebar list is removed — the window title carries the name. The two-column
`NavigationSplitView` shell, pinned sidebar, and the every-detail-pane-carries-
a-toolbar chrome rule are unchanged.

Considered and rejected: an app-wide three-column `NavigationSplitView`
(only Recordings has list→detail depth; per-section column changes make the
window chrome jump), and window-per-transcript (no live detail, window
litter). Chosen: the Recordings pane owns an internal `HSplitView`.

## 4. Recordings pane

### 4.1 List (left side of the split, min ~240 pt, user-resizable)

- **Day-grouped sections.** Section keys derived from `recordingStart` with
  the current calendar: "Today", "Yesterday", weekday + date within the last
  week (e.g. "Monday, June 8"), full date older (e.g. "June 3, 2026"). Row
  titles become time + duration ("2:30 PM · 42:18"); duration omitted when
  unknown (unrefined rows carry `durationSeconds == 0`). `displayTitle`
  ("Today at 2:30 PM") remains for the detail header and notifications.
- **Selection-driven** (`List(selection:)` bound to
  `AppNavigation.selectedRecordingID: String?`). Single click (or arrow-key
  selection) shows the transcript in the detail — selecting *is* opening;
  the existing context menu still works. On pane appear, if the selection is nil
  or its row no longer exists, the newest recording auto-selects so the
  detail is never blank.
- **Search** (`.searchable`) filters by speaker label and the row's date/title
  text. No-results renders `ContentUnavailableView.search`. The synthesized
  live row (below) is exempt from filtering while recording.
- **Exceptional-only status badges.** A steady refined recording shows *no*
  badge. Badges (with `.help` tooltips and accessibility labels, as today):
  - recording now — pulsing red dot + ticking elapsed time (`TimelineView`)
  - queued — clock symbol; context menu gains "Cancel Refinement"
  - refining — small determinate progress (fraction from `queueVM`)
  - failed — red badge with humanized copy; raw `errorClass` in the tooltip;
    Retry in the context menu (only when the queue marked it retryable)
  - not yet refined — subtle orange clock, as today
  Queue state wins over the intrinsic refined flag (preserves today's
  documented `RefineStatusIcon` precedence).
- **Synthesized in-progress row.** While `recording.status == .recording`,
  the list prepends a live row built from the VM's status (id, startedAt) and
  `liveMarkdownURL` (folder = its parent) — no dependence on the scanner
  noticing the new folder (no filesystem race). Once a scan returns an entry
  with the same recording id, the synthesized row dedupes against it (ids are
  stable across refine — documented on `RecordingEntry`).
- Speaker pills are unchanged. The `lastEnqueueError` banner stays, moves to
  `.safeAreaInset(edge: .top)` with a transition.
- Toolbar: Record/Stop (shared, §6), Refresh (kept — R44 scan-on-demand).

### 4.2 Transcript detail (right side, min ~320 pt)

A `TranscriptDetailModel` picks the source for the selected row:

| Selected row state          | Source                                   | Banner |
|-----------------------------|------------------------------------------|--------|
| Recording now               | `LiveTranscriptWatcher` stream           | header shows red Recording badge + elapsed timer |
| Refining                    | file (`final.md` if present else `live.md`) | "Refining 45% · Transcribe" (live from `queueVM`) |
| Unrefined, idle             | `live.md`                                | "This transcript hasn't been refined yet" + Refine button |
| Refined                     | `final.md`                               | none |
| Failed (latest job)         | file as above                            | humanized failure + Retry when retryable |
| No selection / no recordings| —                                        | `ContentUnavailableView` |

- File reads stay async/off-main with the existing three-way result
  (lines / empty-with-placeholder / unreadable-with-error-line) lifted from
  `RecordedTranscriptSheet.load()`. The live path keeps the smart auto-scroll
  and "N new" jump pill via the existing `AutoScrollController`.
- Detail header: `displayTitle`, duration, speaker pills; Copy and Reveal in
  Finder buttons (also still in the row context menu).
- **The fixed-size `RecordedTranscriptSheet` is deleted.**
- When a refine completes for the selected recording, the detail reloads
  (`queueVM.onJobsTerminated` already triggers `scanner.refresh()`; the
  detail model re-reads when its entry's `isRefined`/state changes).

## 5. One transcript renderer

The SwiftUI `LazyVStack` static path in `TranscriptView` is retired. The
NSTextView-backed renderer (`LiveScrollableTranscript`, generalized) becomes
the single implementation, with auto-scroll behavior optional exactly as the
current `autoScroll: AutoScrollController?` parameter works. Wins:

- cross-line text selection in recorded transcripts (broken today — each row
  is independently selectable);
- find-in-transcript via `usesFindBar` / `isIncrementalSearchingEnabled`.
  **Risk flag for planning:** ⌘F routing in an accessory app without a
  visible menu bar may need an explicit `.keyboardShortcut("f")` hook calling
  `performTextFinderAction(_:)`; verify during implementation and wire
  explicitly if needed.

The detached Live Transcript window keeps this renderer (it already does);
its duplicated in-content header ("Live Transcript" title, Copy, Recording
badge) moves into that window's toolbar.

## 6. Record button

A shared toolbar component present on **all three panes** (each detail pane
already must carry a `.toolbar` — chrome rule), leading placement:

- idle → "Record" with red-filled circle symbol
- launching → spinner + "Starting…", disabled
- recording → "Stop · 12:34" (ticking, red tint)
- crashed/error → Record shown but disabled (`.crashed`/`.error` are not
  startable states); the banner's Recover/Dismiss resolves it back to idle

Behavior: pressing Record calls `recording.startRecording()` and sets
`navigation.section = .recordings`. When status transitions idle→recording,
the recordings pane auto-selects the synthesized live row (transition-edge
only — it must not fight the user's selection afterwards). Record-and-watch
is therefore one click from anywhere in the window. The global-hotkey and
menubar flows are untouched (no window is opened or focused by them).

Crash recovery parity: the Recordings pane shows the crashed-state banner
with "Recover Transcript" / "Dismiss" mirroring the menubar dropdown, so the
window is self-sufficient.

## 7. Refinements pane folded into Recordings

`RefinementsListView` and `AppSection.refinements` are deleted. Coverage map:

| Today (Refinements pane)        | After                                    |
|---------------------------------|------------------------------------------|
| Running row + progress          | row badge (§4.1) + detail banner (§4.2)  |
| Queued rows + Cancel            | row badge + "Cancel Refinement" context item |
| Recent completed rows           | (intentionally dropped — steady state needs no UI; notifications already announce completion) |
| Failed rows + Retry + tooltip   | row badge + Retry context item + tooltip |
| Re-enqueue from recent          | "Refine" context item (already exists)   |
| Orphan jobs (folder deleted)    | dropped silently — no row, no UI         |

The menubar dropdown's status line and determinate progress bar are
unchanged.

## 8. Consistency and polish sweep

- **Empty states** → `ContentUnavailableView` with actions: Recordings gets
  "Start Recording" (PRD quick-start CTA), Speakers keeps record-first
  guidance, detail pane gets "Select a recording".
- **Speakers list** adopts the same selection model: single selection;
  Return (or double-click, as today) starts inline rename; Merge/Split
  sheets seed from the selection instead of "first two speakers". Context
  menu and delete-with-undo-toast behavior unchanged.
- **Banners/toasts**: Speakers error + undo overlays move from `.overlay` to
  `.safeAreaInset`; all banners/toasts get appear/disappear transitions
  (`.move + .opacity`, `.animation(_:value:)`). WCAG-checked tint scheme kept.
- **Merge/split sheets** get `minWidth`/`minHeight` instead of fixed frames.
- **Menubar dropdown hover** switches hardcoded `.white`-on-accent to
  `Color(nsColor: .selectedMenuItemTextColor)` /
  `.selectedContentBackgroundColor` (correct under user accent colors).
- **Settings**: output-folder row wrapped in `LabeledContent("Location")`.

## 9. New/changed components

Per D27, all new logic lives in `PulsarTraceMenuBar` (testable, SwiftUI-free
where possible); views in `pulsartrace-mac` stay pure bindings.

| Component | Target | Role |
|-----------|--------|------|
| `RecordingsPaneModel` (new, `@Observable`) | PulsarTraceMenuBar | Composes scanner entries + recording status + queue state + search text into day sections of row models: live-row synthesis & dedup, badge derivation (absorbs `RefineStatusIcon` precedence logic), filtering, auto-select rules. |
| `TranscriptDetailModel` (new, `@Observable`) | PulsarTraceMenuBar | Source decision table (§4.2), async file loading, refine-progress banner state, reload triggers. |
| `AppNavigation` (modified) | PulsarTraceMenuBar | Drops `.refinements`; gains `selectedRecordingID: String?` (process-lifetime, like `section`). |
| `RecordingsSplitView` (new; replaces `RecordingsListView` content) | pulsartrace-mac | `HSplitView`: list + detail, toolbar. |
| `TranscriptDetailView` (new) | pulsartrace-mac | Header + banner + renderer. |
| `RecordToolbarButton` (new) | pulsartrace-mac | Shared toolbar item, all panes. |
| `TranscriptView` (modified) | pulsartrace-mac | Single NSTextView renderer; find bar. |
| `RefinementsListView` (deleted), `RecordedTranscriptSheet` (deleted) | pulsartrace-mac | Folded per §7 / §4.2. |
| `SpeakerEditorView`, `SettingsView`, `LiveTranscriptView`, `MenuBarMenuView`, `MainWindowView` (modified) | pulsartrace-mac | §8 sweep; sidebar heading removal. |

## 10. Error handling

- Detail file-read failure → explicit error line + Retry (re-read) in the
  detail, never a silent empty pane.
- Crashed recording → banner in the Recordings pane (Recover/Dismiss) and
  the existing menubar treatment; the synthesized live row is removed when
  status leaves `.recording` (the folder row reappears via scan as
  unrefined, and crash recovery enqueues refine on it).
- Enqueue failures → existing dismissible banner, now inset + animated.
- Selected recording deleted from disk → next scan drops the row; selection
  falls back to newest (auto-select rule §4.1).
- Live row with `live.md` not yet created (engine still starting) → watcher
  simply has no lines yet; detail shows the existing "Waiting for
  transcript…" placeholder.

## 11. Testing

New suites in `Tests/MenuBarTests` (Swift Testing, `@MainActor`, throwaway
`UserDefaults` + `MenuBarFixtures.tempDir()` conventions):

- `RecordingsPaneModelTests` — day-section keys across date boundaries
  (fixed reference dates, category-level assertions, not locale strings);
  search filtering incl. live-row exemption; badge precedence (queue wins
  over intrinsic; cancelled/unknown falls through — preserves today's
  behavior); live-row synthesis, dedup on id, removal on stop; auto-select
  rules (nil/stale selection → newest; idle→recording edge → live row;
  no re-select mid-recording).
- `TranscriptDetailModelTests` — source decision table (§4.2) including
  failed-job banner; three-way load result; reload on refine completion.
- Existing suites: `AppSection`-related and `RefinementsListView`-adjacent
  tests updated for the deleted pane; everything else untouched.

Verification: bare `swift build`, then `swift test --filter MenuBar`,
`--filter UnitTests`, `--filter Refinement` (no new cross-suite IPC
exposure; the broad `PipelineTests` filter stays off-limits per CLAUDE.md).
Manual GUI smoke (`scripts/make-dev-app.sh`) at branch finish: record →
watch live detail → stop → watch row settle through refine → search, day
groups, speakers rename/merge, find-in-transcript, both empty states.

## 12. Open questions deferred to planning

- Exact `RecordPlan.recordingId` vs `RecordingFolder.recordingId(forName:)`
  equivalence for the synthesized row's id (documented as stable; verify at
  implementation and pin with a test).
- ⌘F routing in the accessory app (§5 risk flag).
- Whether `HSplitView` divider position should persist (nice-to-have;
  `@AppStorage` if trivial, dropped otherwise — YAGNI).
