# PT-P6-E5 · Recording Tools & Discovery — Specification

**Status:** Frozen · **Opened:** 2026-06-26 · **Closed:** 2026-06-29

## Intent

Add the recording-management tools and the discovery surface: `rename_recording` (writes the
recording's title sidecar), `request_refine` (enqueues a refine job and returns immediately), the
`manual` tool returning a standalone operations manual, and rich self-documenting descriptions and
input schemas for every tool. Implements PT-P6-R6 and PT-P6-R8. Extends the MCP Server (PT-C22);
writes the recording title and drives the Refinement Job Queue (PT-C17) through the Menubar
(PT-C16); the manual is sourced from one versioned Markdown file under the MCP target. Depends on
PT-P6-E2 (and references the tools added in PT-P6-E3 / E4 for the description pass).

## Acceptance criteria

- `rename_recording` sets a recording's title and the change appears in the next `list_recordings`.
- `request_refine` enqueues a refine job and returns immediately, without blocking on the pass.
- The `manual` tool returns the operations manual; the manual describes PulsarTrace on its own terms
  and names no external program, service, or workflow.
- `tools/list` carries a description and an input schema for every one of the surface's 17 tools.

## Tasks

- PT-P6-E5-T1 — `rename_recording`: write the title sidecar; reflected in the next listing.
- PT-P6-E5-T2 — `request_refine`: enqueue onto the refine queue and return immediately.
- PT-P6-E5-T3 — `manual.md` content plus the `manual` tool that returns it; a test asserts the
  manual names no external system.
- PT-P6-E5-T4 — the description / schema pass over all 17 tools; assert `tools/list` carries a
  description and schema for each.
