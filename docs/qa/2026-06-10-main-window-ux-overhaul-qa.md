# Manual QA — Main Window UX Overhaul

Click-through verification for the `feat/main-window-ux-overhaul` branch
(design: `docs/specs/2026-06-10-main-window-ux-overhaul-design.md`). Every
automated suite is green; this list covers what only a human at the GUI can
verify. Budget ~20 minutes, one short recording (~1–2 min of any audio —
a YouTube video works for the system stream).

## Setup

```
scripts/make-dev-app.sh
open .build/PulsarTrace.app
```

Have at least one previously refined recording on disk if possible (any run
from before this branch works — note its `live.md` will still show the old
`(provisional)` labels until re-refined; that's the accepted legacy behavior).

## 1. Window frame & sidebar

- [ ] Open the main window from the menubar. It opens ~1104×736 with the
      recordings list taking ~40% of the width (transcript detail ~60%);
      the sidebar shows only **Recordings / Speakers / Settings** — no
      "Refinements" item and no "PulsarTrace" heading above the list.
- [ ] Quit with the window open, relaunch the app: the restored window is
      active immediately — toolbar buttons and list selection draw in full
      color, no greyed "background window" look until you click away and
      back (QA round 4 regression).
- [ ] Resize the window down: it stops at 800 pt wide. Neither the recordings
      list (≥240) nor the transcript detail (≥320) collapses; no Auto Layout
      complaints in Console.

## 2. Record → live detail → stop → refine lifecycle (the core loop)

- [ ] Click **Record** in the toolbar. The app navigates to Recordings, a new
      row appears at the top of **Today** with a pulsing red dot + ticking
      elapsed time, the row is auto-selected, and the detail header shows a
      red ticking badge.
- [ ] Play some audio. Live lines stream into the detail pane; system
      speakers are labelled **`Them?`** (a bare `?`, not "(provisional)").
      The view follows new lines while you're at the bottom.
- [ ] Scroll up mid-recording: following stops and a "N new" pill appears
      bottom-right; clicking it jumps back down and resumes following.
- [ ] The toolbar shows **Stop · M:SS** ticking. The menubar icon is the
      normal waveform with a small red dot at its bottom-right corner while
      recording — deliberately NO ticking timer up there (a ticking
      status-item label spun the main thread to 93% CPU and froze the whole
      UI on macOS 26.5; incident 2026-06-11). While recording,
      `pulsartrace-mac` should sit in single-digit CPU in Activity Monitor —
      that's the regression check.
- [ ] Click **Stop**. The row stays in the list (no blink-out), its badge
      flips to a clock (queued) and then to a small progress bar (refining);
      the detail banner shows "Queued for refinement" → "Refining · stage"
      with a Cancel button.
- [ ] Let the refine finish **while the row is selected**: the content does
      NOT swap under you; a green "Refinement complete — Show refined
      transcript" banner appears. Clicking the button loads `final.md`
      (labels lose the `?`).
- [ ] Refine another recording while reading a DIFFERENT one (context menu →
      Refine on an unrefined row): when it completes, that row (not yours)
      shows a transient green check, which disappears the moment you select
      it. Your reading position never moved.

## 3. Hotkey start must not steal the selection

- [ ] Select an old recording and stay on it. Start a recording with the
      global hotkey (not the button). The live row appears with its pulsing
      badge, but the selection and the transcript you're reading do NOT
      change. Stop via the menubar.

## 4. List: groups, filter, rename, trash

- [ ] Single-clicking any row — title, blank space, pills, badge — opens that
      recording in the detail pane, **every time** (click around briskly;
      no click may be dropped).
- [ ] Rows are grouped under **Today / Yesterday / \<weekday, date\> /
      \<full date\>** headers, newest first. Refined rows show time + duration
      and speaker pills; unrefined rows show an orange clock. On unnamed rows
      the duration after the time ("7:10 AM · 50:11") renders smaller and
      greyed, so it doesn't read as part of the title.
- [ ] Select an unrefined row: its clock badge stays visible on the
      highlighted row (drawn in the selection's foreground color, not
      orange) — it must not vanish into the accent fill (regression:
      QA round 5).
- [ ] Type in the filter field ("Filter by title, speaker, or date"): a
      speaker name matches refined rows; "yesterday" matches yesterday's
      rows; gibberish shows the no-matches state. Clearing restores all. A
      live recording row stays visible regardless of the filter.
- [ ] **Double-click a row's title** (or its time/caption line): selection
      does not glitch, and an inline text field appears (pre-selected).
      Double-clicking blank row space, speaker pills, or the badge only
      selects — no editor. Type "Test title", press Return:
      the row title becomes "Test title" with the time · duration line as a
      caption beneath; the detail header shows the custom title with the date
      caption. The filter now matches "test".
- [ ] Rename survives navigation: double-click a title, type something, then
      click **Record** or switch to Speakers — coming back, the title was
      committed (not lost). Clicking anywhere outside the field also commits.
      Escape during rename cancels.
- [ ] Clear the title (rename → select-all → delete → Return): the date-based
      default returns (`title.txt` removed from the folder).
- [ ] Right-click → **Move to Trash** (or select + ⌫): the folder lands in
      the macOS Trash, the row disappears, and the selection falls back to
      the newest remaining row. Put it back from the Trash + Refresh: it
      reappears with its custom title intact.

## 5. Transcript detail

- [ ] Static transcripts open at the TOP (not scrolled to bottom), and
      cross-line text selection works (drag across several rows; ⌘C).
- [ ] **Copy** (header button) pastes rendered text (`[00:00:03] Them?  …`),
      not raw Markdown (`**[00:00:03] Them?:** …`).
- [ ] **⌘F** (or the Find button) opens the find bar inside the transcript;
      incremental search highlights matches. Also works in the detached Live
      Transcript window.
- [ ] **Reveal in Finder** opens the recording folder.
- [ ] No selection (e.g. all recordings trashed): the detail shows "Select a
      recording"; an empty list shows "No Recordings" with a Record button.

## 6. Record button states & failure banners

- [ ] While idle: "Record" enabled on ALL three panes (Recordings, Speakers,
      Settings). While recording: red "Stop · M:SS" everywhere.
- [ ] Start failure (e.g. revoke microphone permission in System Settings →
      Privacy, then Record): an error banner with the remediation message
      appears at the top of the Recordings pane with **Dismiss** only; the
      Record button is disabled with the reason as its tooltip. Dismiss
      returns to idle. (Re-grant the permission afterwards.)

## 7. Speakers pane

- [ ] Clicking a speaker row highlights it **every time**. Selection is
      visual only — there are no Merge/Split toolbar buttons; every action
      lives on double-click (rename) or the right-click menu.
- [ ] Right-click a speaker → **Merge With** lists every other live speaker.
      Picking one raises a confirmation ("Merge ‘B’ into ‘A’?") with the
      number of recordings to rewrite; confirming folds the picked speaker
      into the right-clicked one (the picked one moves to Recently Deleted,
      their lines relabel).
- [ ] Right-click a speaker who appears in meetings → **Split…**: the sheet
      is titled with that speaker's name and lists their recordings — a
      speaker with meetings must NEVER show an empty list (regression:
      QA round 3). Split enables only with a new name + at least one ticked
      recording.
- [ ] Open a rename (double-click), click away without editing: the field
      closes and nothing happens — no progress spinner, no rewrite (an
      unchanged name is a no-op).
- [ ] Rows under "Recently Deleted"/"Recently Delisted" cannot be selected
      and offer no context-menu actions — Restore only.
- [ ] Double-click rename still works (selection must not glitch): Return
      saves, Escape cancels, and clicking anywhere outside the field saves —
      the field never stays open after a click-away. The split sheet can be
      resized larger.
- [ ] Trigger an error (e.g. rename a speaker to a name containing `+`):
      the error banner sits above the list without covering rows, animates
      in/out, and its ✕ dismisses. Delete a speaker: the undo toast sits
      below the list, same behavior.

## 8. Divider, persistence & polish

- [ ] Drag the list/detail divider; quit (⌘Q) and relaunch: the divider
      position is restored. Window size/position restore too.
- [ ] System Settings → Appearance → set the accent color to e.g. orange:
      the menubar dropdown's hover highlight follows it (no hardcoded blue),
      with legible text. Check dark mode too.
- [ ] Settings: the output-folder row reads "Location" with the path and
      Choose… aligned like the other rows.
- [ ] Detached Live Transcript window: title/Recording badge/Find/Copy live
      in the toolbar (no in-content header), and the Recording badge appears
      only while recording — no ghost toolbar button. The badge's red dot
      has breathing room, not flush against the badge's leading edge
      (QA round 5).

## Known/accepted behaviors (not bugs)

- Old `live.md` files keep `(provisional)` labels until their recording is
  re-refined (no migration, by design).
- ⌫ on the live (in-progress) row is a silent no-op (can't trash a live
  recording; the context item is disabled).
- Day-group headers ("Today"/"Yesterday") refresh on the next state change
  after midnight, not at the stroke of midnight.
- Double-clicking row B's title while row A's rename field is open commits A
  first (Save semantics), then starts renaming B.
- The 40–60 split and the 1104×736 size are first-run defaults: once you
  drag the divider or resize the window, your positions win (the divider
  default landed by bumping the autosave key, so it applies once even on
  machines that saved a position under the old key).
