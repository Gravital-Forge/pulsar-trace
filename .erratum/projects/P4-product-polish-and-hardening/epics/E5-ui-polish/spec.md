# PT-P4-E5 · UI Polish — Specification

**Status:** Frozen · **Opened:** 2026-06-10 · **Closed:** 2026-06-10

## Intent

Polish the interface: styled transcript rendering, a glanceable menubar icon, system notifications
on refinement completion/failure (PT-P4-R8), a direct hotkey recorder, and an accessibility pass
(PT-P4-R7). Touches the Menubar Application (PT-C16).

## Acceptance criteria

- Transcripts render as styled rows (timestamp / speaker / text) rather than raw Markdown.
- A refinement completing or failing posts a system notification (when bundled).
- The global hotkey is recorded directly in settings; interactive controls carry accessibility
  labels.

## Tasks

- PT-P4-E5-T1 — Styled transcript rendering + glanceable menubar icon
- PT-P4-E5-T2 — Refinement completion/failure notifications
- PT-P4-E5-T3 — Hotkey recorder; accessibility labels
