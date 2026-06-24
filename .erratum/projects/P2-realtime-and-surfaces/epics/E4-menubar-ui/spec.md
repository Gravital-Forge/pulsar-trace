# PT-P2-E4 · Menubar UI — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Make the whole flow reachable without a terminal: menubar status, recording control, and persisted
settings (PT-P2-R10); a speaker-library editor, a recordings list, and a live preview (PT-P2-R11);
and retroactive transcript rewrite on speaker edits, paying the deferral from PT-P1-D16 (PT-P2-R12).
Reuses the in-process refiner and the speaker library (PT-C4, PT-C5).

## Acceptance criteria

- Recording can be started (incl. global hotkey), observed, and stopped from the menubar; settings
  persist.
- Speakers can be edited and recordings browsed and re-refined; the live preview updates read-only.
- A speaker rename/merge/split rewrites every affected final transcript atomically and emits the
  paired event; the live transcript is never touched.

## Tasks

- PT-P2-E4-T1 — `PulsarTraceMenuBar` library: status machine, recording VM, settings, hotkey
- PT-P2-E4-T2 — Speaker editor, recordings scanner, live-transcript watcher
- PT-P2-E4-T3 — Retroactive final-transcript rewriter + paired rewrite events
- PT-P2-E4-T4 — `pulsartrace-mac` menubar shell
