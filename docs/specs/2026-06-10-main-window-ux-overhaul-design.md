# Main Window UX Overhaul — Master–Detail Recordings, In-Window Live Transcript, Queue Folding

- **Status:** design approved 2026-06-10 (brainstormed; visual/IA decisions delegated to the agent by the user — "more polished, internally consistent, feels good"). Amended same day after an adversarial UX review by a second agent: action-scoped auto-select, user-mediated refine swap, filter field instead of `.searchable`, window min-size math, transient completion badge, Move to Trash, distinct `.error` banner, renderer scroll/append requirements, speakers multi-select.
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
   recordings are a flat undifferentiated list with no filtering.
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
- Day-grouped, filterable, selection-driven recordings list with
  exceptional-only status badges (plus a transient just-completed badge).
- Recordings can be moved to the Trash from the list.
- `ContentUnavailableView` empty states with actions (the PRD's R44 epic
  explicitly asks for a quick-start CTA in the recordings empty state).
- One transcript renderer (the NSTextView-backed path) everywhere: fixes
  cross-line selection, enables find-in-transcript (⌘F).
- Internal consistency sweep: Speakers list adopts a selection model;
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
- No user-assignable recording titles in this round — named follow-up (§13).

## 3. Information architecture and window frame

Sidebar shrinks to three sections: **Recordings, Speakers, Settings**
(`AppSection.refinements` deleted). The "PulsarTrace" text heading above the
sidebar list is removed; the main window is deliberately brandless in-content
(the per-pane `.navigationTitle` stays — same as Apple's own one-window
apps; the brand lives in the menubar icon and the window's title in the
Windows menu). The two-column `NavigationSplitView` shell, pinned sidebar,
and the every-detail-pane-carries-a-toolbar chrome rule are unchanged.

**Window frame math** (the split's minimums must fit): sidebar 210 +
list ≥ 240 + detail ≥ 320 + dividers ≈ 790. The window's `minWidth` rises
from 640 to **800**, `defaultSize` from 760×480 to **900×560**. The split
divider position **persists across launches** (`@AppStorage`; if
`HSplitView` min-width handling proves unreliable at small sizes, fall back
to an `NSViewRepresentable` `NSSplitView` with `autosaveName`).

Considered and rejected: an app-wide three-column `NavigationSplitView`
(only Recordings has list→detail depth; per-section column changes make the
window chrome jump), and window-per-transcript (no live detail, window
litter). Chosen: the Recordings pane owns an internal resizable split.

## 4. Recordings pane

### 4.1 List (left side of the split, min 240 pt, user-resizable)

- **Day-grouped sections.** Section keys derived from `recordingStart` with
  the current calendar: "Today", "Yesterday", weekday + date within the last
  week (e.g. "Monday, June 8"), full date older (e.g. "June 3, 2026"). Row
  titles become time + duration ("2:30 PM · 42:18"); duration omitted when
  unknown (unrefined rows carry `durationSeconds == 0`). `displayTitle`
  ("Today at 2:30 PM") remains for the detail header and notifications.
- **Selection-driven** (`List(selection:)` bound to
  `AppNavigation.selectedRecordingID: String?`). Single click (or arrow-key
  selection) shows the transcript in the detail — selecting *is* opening;
  the existing context menu still works. On pane appear, if the selection is
  nil or its row no longer exists, the newest recording auto-selects so the
  detail is never blank.
- **Filter field, not `.searchable`.** An inline filter field pinned to the
  top of the *list column* (prompt: "Filter by speaker or date"). Rationale:
  a toolbar-level `.searchable` field next to a transcript reads as
  search-the-transcript and would fail the natural topic-word queries
  (speaker labels exist only on refined rows); it would also fight ⌘F.
  ⌘F is reserved exclusively for find-in-transcript (§5). The synthesized
  live row is exempt from filtering while recording. No matches → inline
  "No matches" placeholder in the list column.
- **Exceptional-only status badges** (with `.help` tooltips and
  accessibility labels, as today). A steady refined recording shows *no*
  badge. Badges:
  - recording now — pulsing red dot + ticking elapsed time (`TimelineView`)
  - queued — clock symbol
  - refining — small determinate progress (fraction from `queueVM`)
  - failed — red badge with humanized copy; raw `errorClass` in the tooltip
  - not yet refined — subtle orange clock, as today
  - **just refined — transient green check**: shown while the recording's
    latest terminal job in `queueVM.recent` is `.completed` AND the row has
    not been selected since completion AND less than ~5 minutes have passed
    (injectable clock for tests). Gives the queued→refining wait a visible
    ending even when the notification was missed/denied, without permanent
    check-mark noise.
  Queue state wins over the intrinsic refined flag (preserves today's
  documented `RefineStatusIcon` precedence).
- **Context menu**: View Transcript (selects), Reveal in Finder, Refine
  (disabled while in flight), Cancel Refinement (queued rows), Retry
  (failed rows, only when the queue marked the failure retryable), and
  **Move to Trash** (also bound to ⌫ on the selection) via
  `NSWorkspace.shared.recycle` — the Trash itself is the undo, no new
  machinery; the scanner refreshes after and the selection falls back per
  the auto-select rule.
- **Synthesized in-progress row.** While `recording.status == .recording`,
  the list prepends a live row built from the VM's status (id, startedAt) and
  `liveMarkdownURL` (folder = its parent) — no dependence on the scanner
  noticing the new folder (no filesystem race). Once a scan returns an entry
  with the same recording id, the synthesized row dedupes against it (ids are
  stable across refine — documented on `RecordingEntry`).
- Speaker pills are unchanged. The `lastEnqueueError` banner stays, moves to
  `.safeAreaInset(edge: .top)` with a transition.
- Toolbar: Record/Stop (shared, §6), Refresh (kept — R44 scan-on-demand).

### 4.2 Transcript detail (right side, min 320 pt)

A `TranscriptDetailModel` picks the source and banner for the selected row:

| Selected row state          | Source                                      | Banner |
|-----------------------------|----------------------------------------------|--------|
| Recording now               | `LiveTranscriptWatcher` stream               | header shows red Recording badge + elapsed timer |
| Queued                      | file (`final.md` if present else `live.md`)  | "Queued for refinement" + **Cancel** |
| Refining                    | file as above                                | "Refining 45% · Transcribe" (live from `queueVM`) + **Cancel** |
| Refine just completed       | file content currently on screen (unchanged) | "Refinement complete" + **Show refined transcript** button |
| Unrefined, idle             | `live.md`                                    | "This transcript hasn't been refined yet" + Refine button |
| Refined                     | `final.md`                                   | none |
| Failed (latest job)         | file as above                                | humanized failure + Retry when retryable |
| No selection / no recordings| —                                            | `ContentUnavailableView` |

- **Refine completion never swaps content under the user.** The refined
  transcript is not the live text plus polish — labels, wording, and line
  structure change, so an automatic reload would destroy scroll position and
  selection mid-read. When a refine completes for the on-screen recording,
  the banner flips to "Refinement complete — Show refined transcript" and
  the content reloads on click — or naturally on the next selection change.
  Only when the detail is showing a placeholder or error (nothing to
  disturb) does it reload immediately.
- File reads stay async/off-main with the existing three-way result
  (lines / empty-with-placeholder / unreadable-with-error-line) lifted from
  `RecordedTranscriptSheet.load()`. The live path keeps the smart auto-scroll
  and "N new" jump pill via the existing `AutoScrollController`.
- Detail header: `displayTitle`, duration, speaker pills; Copy and Reveal in
  Finder buttons (also still in the row context menu).
- **The fixed-size `RecordedTranscriptSheet` is deleted.**

## 5. One transcript renderer

The SwiftUI `LazyVStack` static path in `TranscriptView` is retired. The
NSTextView-backed renderer (`LiveScrollableTranscript`, generalized) becomes
the single implementation, with auto-scroll behavior optional exactly as the
current `autoScroll: AutoScrollController?` parameter works. Wins:

- cross-line text selection in recorded transcripts (broken today — each row
  is independently selectable);
- find-in-transcript via `usesFindBar` / `isIncrementalSearchingEnabled`,
  on ⌘F exclusively (the list filter field deliberately does not claim it).
  **Risk flag for planning:** ⌘F routing in an accessory app without a
  visible menu bar may need an explicit `.keyboardShortcut("f")` hook calling
  `performTextFinderAction(_:)`; verify during implementation and wire
  explicitly if needed.

Two explicit requirements (not discoveries):

- **Initial scroll position depends on mode**: live (auto-scroll controller
  present) opens at the bottom, as today; static transcripts open at the
  **top** — the current `makeNSView` always scrolls to bottom and must be
  parameterized.
- **Suffix-append fast path**: live updates append
  `lines[oldCount...]` to the existing `textStorage` instead of rebuilding
  the full attributed string per poll tick (the rebuild is acknowledged as a
  scaling hazard in the current code; under this design the renderer becomes
  the primary surface for multi-hour meetings, possibly twice concurrently
  — main-window detail + detached window). Full rebuild remains the fallback
  when the line count shrinks (truncation/overwrite).

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
  startable states), with a `.help` tooltip carrying the short reason; the
  pane banner (below) resolves the state back to idle

**Navigation and auto-select are scoped to the button action, not the
status transition.** Pressing Record calls `recording.startRecording()`,
sets `navigation.section = .recordings`, and selects the synthesized live
row once it appears — a direct response to the user's click. Recording
started via global hotkey or the menubar must NOT change the window's
selection or section: if the user is reading an old transcript and starts a
recording with the hotkey, the live row appears with its pulsing badge but
the reading is not interrupted. (An earlier draft triggered auto-select on
the idle→recording status edge; rejected in review because the same edge
fires for hotkey starts.) Planning note: the button-driven navigation away
from Speakers must not silently reset an in-progress inline rename — commit
or preserve the field.

Crash/error parity (the window must be self-sufficient; today both states
surface only in the menubar dropdown):

- `.crashed` → banner on the Recordings pane: "Recording stopped
  unexpectedly" + **Recover Transcript** / **Dismiss** (mirrors the menubar).
- `.error` → distinct banner showing the VM's guidance message verbatim
  (these are carefully written: permission remediation paths, whisper-lock
  retry advice) + **Dismiss** only — "Recover" is nonsensical here.

## 7. Refinements pane folded into Recordings

`RefinementsListView` and `AppSection.refinements` are deleted. Coverage map:

| Today (Refinements pane)        | After                                    |
|---------------------------------|------------------------------------------|
| Running row + progress          | row badge (§4.1) + detail banner with Cancel (§4.2) |
| Queued rows + Cancel            | row badge + "Cancel Refinement" context item + detail banner Cancel |
| Recent completed rows           | transient just-refined row badge (§4.1) + completion banner (§4.2) + existing notification |
| Failed rows + Retry + tooltip   | row badge + Retry (context item + detail banner) + tooltip |
| Re-enqueue from recent          | "Refine" context item (already exists)   |
| Orphan jobs (folder deleted)    | dropped silently — no row, no UI         |

The menubar dropdown's status line and determinate progress bar are
unchanged.

## 8. Consistency and polish sweep

- **Empty states** → `ContentUnavailableView` with actions: Recordings gets
  "Start Recording" (PRD quick-start CTA), Speakers keeps record-first
  guidance, detail pane gets "Select a recording".
- **Speakers list** becomes selection-driven with **multi-select**
  (`Set<String>` selection): ⌘-click two speakers enables **Merge** in the
  toolbar with both operands pre-seeded (sheet pickers stay editable —
  which one to keep is still an explicit choice); exactly one selection
  enables **Split** and Return-to-rename (double-click renames too, as
  today). Single-selection seeding was rejected in review: merge is a
  two-operand action. Context menu and delete-with-undo-toast behavior
  unchanged. **Risk flags for planning:** the per-row
  `.onTapGesture(count: 2)` can swallow the first selection click in macOS
  SwiftUI `List`s; Return-to-rename needs deliberate key routing in an
  accessory app (same class as the ⌘F flag).
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
| `RecordingsPaneModel` (new, `@Observable`) | PulsarTraceMenuBar | Composes scanner entries + recording status + queue state + filter text into day sections of row models: live-row synthesis & dedup, badge derivation incl. transient just-refined window (absorbs `RefineStatusIcon` precedence logic; injectable clock), filtering, auto-select rules, move-to-Trash (recycle + refresh + selection fallback). |
| `TranscriptDetailModel` (new, `@Observable`) | PulsarTraceMenuBar | Source/banner decision table (§4.2), async file loading, pending-refined-content gate (banner-mediated swap), reload triggers. |
| `AppNavigation` (modified) | PulsarTraceMenuBar | Drops `.refinements`; gains `selectedRecordingID: String?` (process-lifetime, like `section`). |
| `RecordingsSplitView` (new; replaces `RecordingsListView` content) | pulsartrace-mac | Resizable split: list + detail, toolbar, divider persistence. |
| `TranscriptDetailView` (new) | pulsartrace-mac | Header + banner + renderer. |
| `RecordToolbarButton` (new) | pulsartrace-mac | Shared toolbar item, all panes; action-scoped navigation. |
| `TranscriptView` (modified) | pulsartrace-mac | Single NSTextView renderer; find bar; mode-dependent initial scroll; suffix-append fast path. |
| `RefinementsListView` (deleted), `RecordedTranscriptSheet` (deleted) | pulsartrace-mac | Folded per §7 / §4.2. |
| `SpeakerEditorView`, `SettingsView`, `LiveTranscriptView`, `MenuBarMenuView`, `MainWindowView`, `PulsarTraceMacApp` (modified) | pulsartrace-mac | §8 sweep; sidebar heading removal; window min/default size (§3). |

## 10. Error handling

- Detail file-read failure → explicit error line + Retry (re-read) in the
  detail, never a silent empty pane.
- Crashed recording → `.crashed` banner in the Recordings pane
  (Recover/Dismiss) and the existing menubar treatment; the synthesized live
  row is removed when status leaves `.recording` (the folder row reappears
  via scan as unrefined, and crash recovery enqueues refine on it).
- Start errors → `.error` banner with the VM's message + Dismiss (§6).
- Enqueue failures → existing dismissible banner, now inset + animated.
- Selected recording deleted from disk (externally or via Move to Trash) →
  next scan drops the row; selection falls back to newest (auto-select rule
  §4.1).
- Live row with `live.md` not yet created (engine still starting) → watcher
  simply has no lines yet; detail shows the existing "Waiting for
  transcript…" placeholder.

## 11. Testing

New suites in `Tests/MenuBarTests` (Swift Testing, `@MainActor`, throwaway
`UserDefaults` + `MenuBarFixtures.tempDir()` conventions):

- `RecordingsPaneModelTests` — day-section keys across date boundaries
  (fixed reference dates, category-level assertions, not locale strings);
  filter matching incl. live-row exemption; badge precedence (queue wins
  over intrinsic; cancelled/unknown falls through — preserves today's
  behavior); transient just-refined badge expiry by clock and by selection
  (injectable clock); live-row synthesis, dedup on id, removal on stop;
  auto-select rules (nil/stale selection → newest; **no** auto-select on
  status transitions — action-scoped only).
- `TranscriptDetailModelTests` — source/banner decision table (§4.2)
  including queued/failed banners; the pending-refined-content gate (no
  auto-swap while content is on screen; swap on explicit action and on
  selection change; immediate reload from placeholder/error); three-way
  load result.
- Existing suites: `AppSection`-related and `RefinementsListView`-adjacent
  tests updated for the deleted pane; everything else untouched.

Verification: bare `swift build`, then `swift test --filter MenuBar`,
`--filter UnitTests`, `--filter Refinement` (no new cross-suite IPC
exposure; the broad `PipelineTests` filter stays off-limits per CLAUDE.md).
Manual GUI smoke (`scripts/make-dev-app.sh`) at branch finish: record →
watch live detail → stop → watch row settle through queued/refining/
completion banner → filter, day groups, Move to Trash, speakers
multi-select merge, find-in-transcript (⌘F), divider persistence across
relaunch, both empty states, hotkey-start-while-reading (selection must not
move).

## 12. Open questions deferred to planning

- Exact `RecordPlan.recordingId` vs `RecordingFolder.recordingId(forName:)`
  equivalence for the synthesized row's id (documented as stable; verify at
  implementation and pin with a test).
- ⌘F routing in the accessory app (§5 risk flag); Return-to-rename key
  routing in the Speakers list (§8 risk flag).
- Double-click rename gesture vs `List` selection click-swallowing on the
  Speakers rows (§8 risk flag) — fall back to Return/context-menu rename
  only if the gesture fights selection.

## 13. Named follow-ups (out of scope, recorded so they aren't lost)

- **User-assignable recording titles** (sidecar file, no engine change) —
  the highest-leverage maturity item not in this round; would also make the
  list filter meaningfully stronger.
- Activation-policy revisit (D27) if the unified window grows into the
  primary surface.
- Speaker "play sample" (R31 remainder).
