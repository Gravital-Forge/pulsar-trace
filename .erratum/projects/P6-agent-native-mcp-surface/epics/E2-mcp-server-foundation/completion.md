# PT-P6-E2 · MCP Server Foundation — Completion Record

**Status:** Frozen · **Closed:** 2026-06-29

## What was built

The in-app, opt-in, loopback MCP server now stands up end to end, with no tools yet (those arrive in
E3–E5).

- **SDK + module.** The official `modelcontextprotocol/swift-sdk` is pinned `exact: "0.12.1"` (library
  product `MCP`). A new non-SwiftUI `PulsarTraceMCP` library target (depends on `MCP` +
  `PulsarTraceEngine`) hosts the server core; an `MCPTests` test target covers it; `pulsartrace-mac`
  depends on `PulsarTraceMCP`. `MCPServerInfo` carries the server identity and default port `8276`.
- **Auth (`MCPAuth`).** A 32-byte hex bearer token generated on first use, persisted owner-only
  (`0600`) at `AppPaths.mcpTokenURL`, reused across launches, regenerable; per-request validation pairs
  `bearerToken(from:)` (parses `Authorization: Bearer …`) with a constant-time `constantTimeEquals`.
- **Loopback front end (`LoopbackHTTPListener`).** The project's first `Network.framework` use — an
  `NWListener` bound `127.0.0.1`-only (`requiredInterfaceType = .loopback`), ephemeral port via
  `port == 0`, a `Content-Length`-gated HTTP/1.1 request parser, single-response write with
  `Connection: close`, and `ListenerState` transitions (`ready`/`waiting`/`failed`, the last two
  flagging `EADDRINUSE`) observable via `onStateChange`. `@unchecked Sendable` + `NSLock`, mirroring
  the POSIX capture sockets' teardown discipline.
- **Server (`MCPServer`).** An actor wiring the SDK `Server` (tools capability) to a
  `StatelessHTTPServerTransport` behind the listener: `POST /mcp` is bearer-gated and forwarded to the
  transport, `GET /mcp` → 405, `GET /healthz` → status JSON. An `initialize` + `tools/list` round-trips
  over real loopback HTTP and returns an empty tool list.
- **Health + supervision.** `MCPServerStatus` (`stopped`/`running(port:)`/`portInUse`/`failed`) is
  exposed as `MCPServer.status` and served at `/healthz`; a lock-guarded `MCPStatusBox` lets the
  listener callback and `/healthz` read status without an actor hop. The supervisor rebuilds a *failed*
  listener with bounded exponential backoff (`MCPSupervisor.backoffDelay`, capped at 30 s, 5 attempts)
  but on a persistent bind clash surfaces `portInUse` and stops — never rotating the port (PT-P6-D3).
- **Settings + lifecycle.** `MenuBarSettings` gains MCP-free persisted `mcpServerEnabled` (default
  `false`) + `mcpServerPort` (default `8276`). An `MCPController` (`@MainActor @Observable`) in the
  composition root `pulsartrace-mac` reconciles the running server against settings on a 1 s loop,
  starts/stops on toggle, and offers `restart()`. The `SettingsView` MCP section shows the toggle, the
  port, the live `/healthz` status (`MCPHealthProbe`), a copyable `claude mcp add …` setup command
  (`MCPConnectionSnippet`), and a Restart button.

## Deltas from the spec

The plan was written against assumed SDK signatures; the implementer verified the real `0.12.1` API
against the resolved checkout and adapted. None of these change the epic's externally-observable
behaviour.

- **Real SDK API (recorded for the tool epics).** `Server(name:version:capabilities:)` with
  `Capabilities(tools: .init(listChanged:))`; `server.start(transport:)` `async throws`, `server.stop()`
  `async` (non-throwing); tools register via `await server.withMethodHandler(ListTools.self){…}` /
  `withMethodHandler(CallTool.self){…}`; `StatelessHTTPServerTransport()` no-arg init,
  `handleRequest(_:) async -> HTTPResponse` (async, **not** throwing); `MCP.HTTPRequest` is a struct
  `init(method:headers:body:path:)`, `MCP.HTTPResponse` an enum with computed `statusCode` / `headers`
  (`[String:String]`) / `bodyData`.
- **No `Host` injection.** The SDK's default `OriginValidator.localhost()` validates only a *present*
  `Host` and its `127.0.0.1:*` pattern requires a numeric port; HTTP clients already send
  `Host: 127.0.0.1:<port>`, so the route forwards it untouched (injecting bare `127.0.0.1` would 421).
- **Empty `ListTools` handler in `start()`.** The SDK auto-registers only `initialize` + `ping`, so an
  explicit empty `ListTools` handler is registered to make `tools/list` return `result.tools == []`;
  E3 replaces it with the real registry.
- **`boundPort()` gates on `.ready`** (the `NWListener` port reads 0 while binding); **`/healthz`
  serializes the port as a numeric Int**, and `MCPHealthProbe` parses it as such.
- **Listener `stop()`/`setState` Swift-6 fix.** Assigning an outer `let` from inside the `withLock`
  closure fails definite-initialization under Swift 6; the value is returned out of `withLock` instead.
- **Lifecycle owner.** Per the second-round dependency-direction finding, the server lifecycle lives in
  an `MCPController` in `pulsartrace-mac`, **not** `AppEnvironment` — `PulsarTraceMenuBar` does not (and
  must not) import `PulsarTraceMCP`. There is no SwiftUI `Settings` scene; the MCP section lives in the
  main window's Settings pane.
- **Manual GUI smoke** (toggle on → socket accepts, copy command, restart, toggle off) is the user's to
  run; `pulsartrace-mac` is not unit-tested by design (PT-P2-D9). The testable units — `MenuBarSettings`
  round-trip and `MCPConnectionSnippet` — pass, and the full package builds.

## Requirements satisfied

- **PT-P6-R1** (in-app, opt-in server, configurable port, no auto-rotate) —
  `Sources/PulsarTraceMCP/MCPServer.swift`, `LoopbackHTTPListener.swift`, `MCPServerInfo.swift`;
  `Sources/pulsartrace-mac/MCPController.swift`; `MenuBarSettings` toggle/port; `Package.swift`.
- **PT-P6-R2** (loopback-only, token-authenticated) — `Sources/PulsarTraceMCP/MCPAuth.swift`, the
  bearer gate in `MCPServer.route`, `AppPaths.mcpTokenURL`; `MCPConnectionSnippet.swift`.
- **PT-P6-R10** (surface excludes settings/capture/content) — satisfied by construction at this stage:
  no tool handlers exist yet, and the route exposes only `/healthz`, `/mcp` (JSON-RPC), and 405/404; the
  toolset epics (E3–E5) preserve it. No handler mutates settings/model or starts/stops capture.
- **PT-P6-R11** (health, supervision, manual restart) — `Sources/PulsarTraceMCP/MCPServerStatus.swift`
  (status + `MCPSupervisor`), the supervision in `MCPServer.swift`, `/healthz`, `MCPHealthProbe.swift`,
  and the Settings Restart button via `MCPController.restart()`.

Code links carry `// PT-P6-R1`, `// PT-P6-R2`, `// PT-P6-R11`.

## To flow into the product layer

At project close-out (per `references/close-out.md`):

- **Mint** the MCP Server component **PT-C22** (provisional in the PRD) for the `PulsarTraceMCP` module
  (listener, auth, server, transport wiring, supervision), and the product requirements for PT-P6-R1,
  PT-P6-R2, PT-P6-R10, PT-P6-R11 (all *Introduce*, from `PT-R115` upward). Note PT-P6-R10 is realised
  across E2–E5; its row's `implemented_by` should point at the whole tool surface, not just E2.
- **Architecture:** describe PT-C22 and the reshape of the Menubar Application (PT-C16) for the settings
  toggle and the composition-root `MCPController`. Record that PT-C22 owns the loopback transport only;
  the LAN move (PT-P6-D9) stays out of scope.
- **Traceability:** write-once rows for the four product requirements, `implemented_by` the symbols
  above.
- **Reference sweep:** re-point every `// PT-P6-R1` / `R2` / `R10` / `R11` code link to its minted
  product requirement id.
