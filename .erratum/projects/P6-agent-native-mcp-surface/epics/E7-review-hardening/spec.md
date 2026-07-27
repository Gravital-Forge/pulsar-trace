# PT-P6-E7 · Review Hardening — Specification

**Status:** Open · **Opened:** 2026-07-01

## Intent

Fold in hardening fixes to the MCP surface surfaced by the 2026-07-01 comprehensive review, while P6
is still in flight. This epic is the home for those corrections so they land as first-class P6 work
rather than edits to the earlier epics. It currently carries one fix — a pre-authentication
denial-of-service in the loopback HTTP front end (`LoopbackHTTPListener`, PT-R115): a request with a
negative `Content-Length` reached `Data.prefix(-1)`, which traps and aborts the process, so any
local process could crash the menubar app with one unauthenticated request while the MCP server is
enabled. Hardens the request parser behind PT-R115; changes no requirement and no component
structure.

## Acceptance criteria

- `LoopbackHTTPRequest.parse` rejects a request whose `Content-Length` is negative, returning `nil`
  (the same "unparseable request" outcome as a truncated header block) rather than trapping — the
  idle-timeout reaper then tears the half-open connection down.
- The existing round-trip and oversized-body (413) behaviours are unchanged.
- Regression proven by a parser-level test in `MCPTests` that exercises a raw buffer (URLSession
  cannot emit a negative `Content-Length`).

## Tasks

- PT-P6-E7-T1 — Failing test for a negative `Content-Length`, then the `expected >= 0` guard in
  `LoopbackHTTPRequest.parse`.
