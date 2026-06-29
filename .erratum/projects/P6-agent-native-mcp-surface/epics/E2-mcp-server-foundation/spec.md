# PT-P6-E2 · MCP Server Foundation — Specification

**Status:** Open · **Opened:** 2026-06-26

## Intent

Stand up the in-app, opt-in, loopback MCP server: add the official MCP Swift SDK, create a
`PulsarTraceMCP` library target that hosts the tool registry and JSON-RPC handlers behind a
hand-rolled `Network.framework` `NWListener` loopback HTTP front end feeding the SDK's
`StatelessHTTPServerTransport`, gate every request with a persistent bearer token, expose a
`/healthz` endpoint, supervise the listener in-process, and add the Settings toggle / port / token
UI with a manual restart. Implements PT-P6-R1, PT-P6-R2, PT-P6-R10, PT-P6-R11. Introduces the MCP
Server component (PT-C22, provisional) and reshapes the Menubar Application (PT-C16) for settings
and lifecycle; preserves the local-only and owner-only posture (PT-R87, PT-R98, PT-R100). The server
hosts no tools yet — they arrive in PT-P6-E3 / E4 / E5.

Two notes from second-round planning. The `NWListener` is the project's **first** `Network.framework`
use — the existing capture sockets are raw POSIX Unix-domain IPC and do not transfer (PT-P6-D2's
rationale was corrected accordingly). And there is no SwiftUI `Settings` scene in this app: settings
live in `SettingsView` (a `Form` pane). The server lifecycle is owned by an `MCPController` in the
composition root `pulsartrace-mac`, **not** `AppEnvironment` — `PulsarTraceMCP` depends on
`PulsarTraceMenuBar`, so the menubar target cannot import the MCP module (that would be circular).

## Acceptance criteria

- The server is disabled by default; enabling it in Settings binds `127.0.0.1` on the configured
  port (default `8276`); a port already in use surfaces a Settings status and the server stays down
  — it never auto-selects a different port.
- Every request must carry a bearer token; the token is generated on first enable, persisted to an
  owner-only (0600) file, reused across launches, and surfaced in Settings as a copyable connection
  snippet; a manual action regenerates it.
- An `initialize` followed by `tools/list` round-trips over loopback HTTP and returns an empty tool
  list; `GET /mcp` returns 405; a request without a valid token is rejected.
- `/healthz` returns the server's status over the loopback; a failed listener is rebuilt with
  bounded backoff; Settings reflects running / down / port-in-use and offers a manual restart.
- The surface mutates no settings or model selection and cannot start or stop capture — verified by
  the absence of any such handler (PT-P6-R10).

## Tasks

- PT-P6-E2-T1 — Add the `modelcontextprotocol/swift-sdk` dependency (pinned exact — pre-1.0) and the
  `PulsarTraceMCP` library + `MCPTests` test targets; `pulsartrace-mac` depends on `PulsarTraceMCP`.
- PT-P6-E2-T2 — `MCPAuth`: persistent owner-only token generation and storage, and per-request
  `Authorization` header validation.
- PT-P6-E2-T3 — `LoopbackHTTPListener`: `NWListener` on `127.0.0.1`; minimal HTTP/1.1 parse and
  single-response write; route table for `POST /mcp`, `GET /healthz`, and `GET /mcp` → 405.
- PT-P6-E2-T4 — `MCPServer`: the SDK `Server` declaring the tools capability, `StatelessHTTPServer`
  transport wiring, and auth enforced ahead of the transport; `initialize` + empty `tools/list`.
- PT-P6-E2-T5 — `/healthz` + `MCPServerStatus` + supervision: rebuild a failed listener with bounded
  backoff; stop-with-error on a repeated bind failure.
- PT-P6-E2-T6 — `MenuBarSettings` (`mcpServerEnabled` default `false`, `mcpServerPort` default
  `8276`), the `MCPController` start/stop lifecycle in `pulsartrace-mac`, and the `SettingsView`
  section (toggle, port + live `/healthz` status, copyable connection snippet, manual restart).
