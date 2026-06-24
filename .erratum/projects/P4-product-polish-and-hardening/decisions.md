# PT-P4 · Product Polish & Hardening — Decision Log

The choices behind tuning, hardening, consolidation, and the main-window rework. Frozen at project
close.

## Decisions

### PT-P4-D1 · Streaming cadence tuned to halve live decode load

*2026-05-29*

**Decision:** The live decode step and window were lengthened (step to a few seconds, window to ten)
to roughly halve live decode load.

**Because:** The live pass was decoding more often than the bounded lag required, leaving no headroom;
a longer step keeps lag acceptable while freeing the recognizer.

### PT-P4-D2 · Per-window live language restricted to an allow-list

*2026-05-29*

**Decision:** Per-window language detection chooses among a user-configured allow-list rather than all
languages, surfaced through a settings picker.

**Because:** Unrestricted per-window detection drifted between languages mid-meeting; an allow-list
keeps it stable for the languages a user actually speaks.

### PT-P4-D3 · On-disk and cross-process privacy hardening

*2026-06-09*

**Decision:** Content files are mode 0600, product-owned directories 0700 (repairing looser existing
permissions), internal sockets authenticate the peer's user, and authoritative writes fsync before
rename.

**Because:** A local-only privacy product must not leave readable content for other local users, and
a same-user socket check plus durable writes close the remaining on-disk and IPC exposure.

### PT-P4-D4 · Maintainability consolidation

*2026-06-09*

**Decision:** Duplicated transcriber cores are unified, the live runner's several responsibilities are
split into focused types, transcript assembly is extracted, and layering leaks are removed — with no
behaviour change.

**Because:** The live and refine paths had accumulated parallel implementations; consolidating them
makes the engine maintainable before the larger backend change ahead.

### PT-P4-D5 · One transcript renderer; master–detail main window

*2026-06-10*

**Decision:** A single transcript renderer is used everywhere and the main window becomes
master–detail, rendering the selected (including live) transcript in-window, with renameable
recordings and find-in-transcript; the separate refinements pane folds into the recording rows.

**Because:** Multiple renderers and a separate status pane fragmented the experience; one renderer and
an in-window detail make the window self-sufficient.

### PT-P4-D6 · Compact provisional marker emitted at the source

*2026-06-10*

**Decision:** The live transcript marks provisional speakers with a compact `?` suffix emitted by the
engine itself, replacing the verbose `(provisional)` text; transcripts written before this keep the
old marker until refined.

**Because:** Marking provisional at the source keeps every reader consistent, and a compact glyph
reads better; the change is a versioned transcript-contract change with a stated migration.
