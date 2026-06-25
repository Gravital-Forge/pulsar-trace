# PT-P6 · Agent-Native MCP Surface — Decision Log

The reasoning behind the agent-native MCP surface, recorded as each choice was taken. Append-only;
frozen at project close.

## Decisions

### PT-P6-D1 · The MCP server is hosted in-process by the menubar app

*2026-06-25*

**Decision:** The MCP server runs inside the `pulsartrace-mac` menubar app, started at app launch
when enabled and stopped on quit, rather than as a standalone CLI subprocess or daemon. Its
tool-handling core lives in a testable, non-SwiftUI library target; the menubar executable owns its
lifecycle.

**Because:** the menubar app is already the single long-running owner of the speaker library.
Hosting the server in that same process means an agent edit and a UI edit are literally the same
code path over the same `SpeakerLibrary` actor — there is no second writer, no stale in-memory
cache, no duplicated event pairing, and no race between two processes rewriting the same `final.md`.
A separate CLI-hosted server would have reintroduced every one of those cross-process hazards. The
cost — the app must be running for the surface to be reachable — is acceptable and was accepted
explicitly.

### PT-P6-D2 · Transport is the official MCP Swift SDK over a hand-rolled loopback listener

*2026-06-25*

**Decision:** The protocol layer is the official `modelcontextprotocol/swift-sdk` using its
`StatelessHTTPServerTransport` (plain `application/json` per request, no SSE). The SDK ships no HTTP
listener, so the loopback front end is a small hand-rolled `Network.framework` `NWListener` that
parses HTTP/1.1 and feeds request bodies into the transport. No general HTTP-server dependency
(FlyingFox, Hummingbird, Vapor) is added.

**Because:** the SDK gives spec-correct JSON-RPC framing, capability negotiation, and the localhost
origin / bearer-token validators for free, and tracks the current MCP spec — but it is a
request/response adapter, not a socket. A tool-only server has no server-initiated messages, so the
stateless, no-SSE transport is sufficient and the simplest correct choice. For the listener, the
project already owns `Network.framework` socket code (the capture sockets, the socket source, peer
authentication), so a single loopback POST endpoint with a 405 on GET is a contained, testable
amount of framing to own — and it avoids stacking a second pre-1.0 dependency on top of the SDK. The
SDK is dual Apache-2.0 / MIT, satisfying PT-R88 (open-source dependencies only). FlyingFox remains a
drop-in swap if owning the HTTP framing proves not worth it.

### PT-P6-D3 · The server is disabled by default, on a configurable fixed port with no auto-rotation

*2026-06-25*

**Decision:** The server ships disabled and runs only when the user enables it in Settings. When
enabled it binds `127.0.0.1` on a configurable port whose default is `8276`. A port conflict is
surfaced in Settings and leaves the server stopped; the app never silently selects a different port.

**Because:** an opt-in default means no listening surface exists on a user's machine unless they ask
for one — the right privacy posture for a local-only product, and the reason the feature does not
weaken PT-R87 for users who never turn it on. `8276` is an uncommon high port chosen to avoid the
usual development, database, and local-model defaults (3000, 5000, 8000, 8080, 8443, 5432, 6379,
11434, 1234, 27017, …); making it configurable lets a user move it if it still collides.
Auto-rotating to a free port on conflict was rejected because a moving port desynchronises whatever
endpoint the agent's client config points at; a stable, explicitly-chosen port keeps that
configuration valid.

### PT-P6-D4 · Access is gated by a per-launch bearer token over loopback only

*2026-06-25*

**Decision:** Every request must present a per-launch bearer token in the `Authorization` header.
The token is generated at launch, persisted to an owner-only (0600) file under the app-support
directory alongside a paste-ready client configuration snippet, and validated on every request in
addition to the SDK's localhost origin check. The listener binds loopback only.

**Because:** loopback restricts callers to local processes, but any local process is otherwise able
to connect — and these tools rewrite the user's transcripts and mutate the speaker library, so
silent access by an arbitrary local process is not acceptable. A static per-launch bearer token is
the standard, low-friction guard for a local app-hosted MCP server and composes with the SDK's
validator pipeline. Storing the token owner-only and binding loopback keeps the feature inside the
product's existing owner-only / local-only posture (PT-R98, PT-R100).

### PT-P6-D5 · No MCP prompts; discovery is self-documenting tools plus a standalone manual

*2026-06-25*

**Decision:** The server exposes no MCP prompt templates. Capability discovery is the native
`tools/list` surface — each tool richly described — augmented by a `manual` tool that returns an
operations manual (data model, operation semantics, reversibility) sourced from one versioned
Markdown file in the repo. The manual and the descriptions describe PulsarTrace on its own terms and
reference no external program, service, or workflow.

**Because:** MCP prompts are user-initiated, surfaced to a human as slash commands — the wrong shape
for a surface whose goal is an agent operating autonomously with minimal human supervision. The
agent should discover the system's capabilities and semantics itself and drive them directly.
Keeping the manual free of any external integration keeps PulsarTrace a standalone application:
workflow that spans PulsarTrace and other systems belongs to the connected agent, not baked into the
product. Shipping the guidance with the server, versioned alongside it, means any connected agent
gets it with no setup.

### PT-P6-D6 · Speaker tools are thin and one-to-one, with full reversible-operation parity

*2026-06-25*

**Decision:** Each speaker operation maps to its own tool — rename, merge, split, unmerge, unsplit,
delete, undelete, delist, undelist — rather than a higher-level "identify" tool that picks a
primitive for the agent. The full inverse set is exposed, not just the forward operations.

**Because:** thin primitives keep policy out of the product — the agent composes whatever
higher-level behaviour it needs and PulsarTrace stays free of inference or workflow logic. Exposing
the complete inverse set is the safety net for autonomous editing: an agent (or the user through it)
can reverse any edit it makes, and every edit already emits an audited event, so an autonomous
mutation is always both reversible and traceable.

### PT-P6-D7 · The speaker-edit orchestration is extracted into a shared service and adopted by the CLI

*2026-06-25*

**Decision:** The library-edit + retroactive-rewrite + paired-event sequence is lifted out of
`SpeakerEditorViewModel` into a reusable engine service injected with the library, the event writer,
and the output-folder roots. The menubar editor, the MCP server, and the CLI `speakers` command all
call it. The CLI's `speakers rename`/`merge`/etc. consequently gain the retroactive `final.md`
rewrite they did not perform before.

**Because:** the rewrite orchestration is the mechanism behind PT-R90, and it must produce identical
file and event effects regardless of who triggers the edit — UI, agent, or CLI. The logic was
verified to be pure data operations, not UI-coupled, so the lift is clean. Adopting it in the CLI
removes a pre-existing inconsistency where a CLI rename left past transcripts stale, which
contradicted the PT-R90 intent; one shared service is the natural place to fix it once.

### PT-P6-D8 · Transcripts and audio are reached by filesystem path, not served over MCP

*2026-06-25*

**Decision:** No tool returns transcript or audio bytes. The query tools return metadata and the
filesystem paths to `final.md`, `live.md`, and the audio files; the agent reads (and, for a live
recording, tails) those paths directly. Tool names are explicit about this — the single-recording
getter is `get_recording_meta`, not `get_recording`.

**Because:** the filesystem is the native, efficient surface for large Markdown and audio, and these
files are already owner-only local artifacts on a contract-stable layout — there is nothing MCP adds
by copying their bytes through a tool result. Keeping content off the surface keeps the tools about
control and metadata, and explicit naming makes the boundary unmistakable: a tool that says `meta`
cannot be mistaken for one that returns the transcript.

### PT-P6-D9 · LAN / off-device transport is out of scope, behind a transport-agnostic core

*2026-06-25*

**Decision:** Only the loopback transport ships. The tool registry and handlers are written
independently of the transport, so binding a non-loopback address (with the stronger authentication
that would require) is a later, isolated addition rather than a rewrite. No LAN binding, and no
authentication beyond the loopback bearer token, is built in this project.

**Because:** off-device reach is a real departure from the local-only posture and carries its own
security design (binding policy, stronger auth, abuse limits) that is not worth taking on now.
Writing the core transport-agnostically costs almost nothing and keeps that option cheap, so the
project can stay local-only today without foreclosing a future LAN surface.
