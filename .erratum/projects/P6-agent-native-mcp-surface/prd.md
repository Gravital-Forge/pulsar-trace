# PT-P6 · Agent-Native MCP Surface — Project PRD

**Status:** Frozen · **Opened:** 2026-06-25 · **Closed:** 2026-06-29

## Scope

This project gives PulsarTrace an agent-native control surface: an in-process **MCP server** hosted
by the menubar app, through which a local AI agent can discover what PulsarTrace holds and drive it
autonomously — listing recordings and their speakers, reading transcripts off disk, and managing
speaker identity and recording titles — with no human stepping through the app's UI.

The surface is a set of MCP **tools**, exposed in three groups. **Query tools** list recordings
(with time-range and status filters) and the speaker library, and fetch a single recording's
metadata or a single speaker with the recordings it appears in; they return identity, timing, state,
and filesystem paths, and never transcript or audio bytes — an agent reads content directly off the
paths. **Management tools** are thin, one-to-one wrappers over the existing speaker operations
(rename, merge, split, their inverses, and delete/delist with their inverses) plus recording
title-set and refine-request; every speaker edit drives the same retroactive transcript rewrite and
paired events as the in-app editor (PT-R90). **Discovery** is the MCP `tools/list` surface itself —
each tool is self-documenting — backed by a `manual` tool that returns a standalone operations
manual describing the data model and the semantics and reversibility of each operation.

PulsarTrace stays a self-contained application. The surface carries no policy and no workflow logic;
it describes the system on its own terms and references no external program or service. Higher-level
behaviour — deciding who an unknown speaker is, what to rename, when to merge — is the connected
agent's to compose from these primitives.

The server is **opt-in and local**. It is disabled by default and starts only when the user enables
it in Settings; it binds the loopback interface (`127.0.0.1`) on a configurable port (default
`8276`); and every request must carry a bearer token. This preserves the product's local-only and
owner-only posture (PT-R87, PT-R98, PT-R100): nothing listens unless the user opts in, nothing is
reachable off the device, and no unauthenticated local process can drive it. The token is persistent
and surfaced in Settings as a paste-ready client-configuration snippet, so the user configures the
agent's MCP client once and it keeps working across app restarts; Settings also shows the server's
health and offers a manual restart.

One refactor underpins the management tools. The speaker-edit orchestration — library mutation with
events suppressed, the `FinalMarkdownRewriter` pass over affected `final.md` files, and the paired
event emission — is today inlined in the menubar's `SpeakerEditorViewModel`. This project extracts
it into a reusable engine service invoked identically by the menubar editor, the MCP server, and the
CLI `speakers` command. Routing the CLI through it also closes a pre-existing gap where
`speakers rename` mutated the library without rewriting transcripts.

The project introduces one new component, **PT-C22 · MCP Server** (provisional; minted at
close-out), and touches the Speaker Library (PT-C5), the Refinement Pipeline's retroactive rewriter
(PT-C4), the Events Log (PT-C6), the Menubar Application (PT-C16), and the Command-Line Interface
(PT-C9). The new shared edit service is described narratively here and given its permanent placement
at close-out.

Out of scope: changing settings or model selection over the surface; starting or stopping capture;
transiting transcript or audio content through MCP (filesystem paths only); and any off-device or
LAN transport. The tool-handling core is kept transport-agnostic so a future loopback-to-LAN move is
an isolated addition rather than a rewrite, but no networked transport ships in this project.

## Project Requirements

Each requirement carries a **type** (functional / technical / constraint) and a **change-type**
against the product layer (Introduce / Supersede(target) / Retire(target)). Every requirement in
this project is an **Introduce**; the product requirement numbers are minted at project close-out
(from `PT-R115` upward, derived max-plus-one over the matrix at that time) and reconciled into
`product/` then — nothing in the product layer moves while the project is open.

### PT-P6-R1 · Technical · Introduce — In-app, opt-in MCP server with configurable port

The menubar app hosts an MCP server in its own process. The server is disabled by default and runs
only while enabled in Settings; when enabled it binds `127.0.0.1` on a user-configurable port
(default `8276`). A port already in use is surfaced as a Settings status without auto-selecting a
different port, so a client's saved endpoint never drifts.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* with the toggle off,
nothing listens on the port; toggling on binds it; an occupied port shows a Settings error and the
server stays down until the user picks a free port.

### PT-P6-R2 · Constraint · Introduce — Loopback-only, token-authenticated access

The server is reachable only on the local loopback interface and requires a bearer token on every
request. The token is generated when the server is first enabled, stored in an owner-only file, and
persists across launches so a configured client keeps working; Settings surfaces it as a paste-ready
client-configuration snippet for the user to copy into the agent's MCP client, and a manual action
regenerates it. No binding to a non-loopback address exists in this project.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* a request without the
valid token is rejected; the token file is owner-only (0600); the token survives an app restart and
regenerating it invalidates the previous one; the listener is bound to `127.0.0.1` and refuses
non-loopback origins.

### PT-P6-R3 · Functional · Introduce — Recording query tools return metadata and paths, never content

Tools list recordings and fetch one recording's metadata. Listing supports a time-range filter
(since / until) and a status filter (live / refined / all). Each result carries the recording's
identity, start time, duration, language, refinement state, a live-in-progress flag, the speakers
present, and filesystem paths to the transcript and audio files. No query tool returns transcript or
audio content.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* the list and get tools
return metadata and paths; a recording in progress is flagged and its live transcript path is
returned; no tool returns transcript bytes.

### PT-P6-R4 · Functional · Introduce — Speaker query tools

Tools list the speaker library and fetch a single speaker together with the recordings in which it
appears. Listing returns each live speaker's id, name, appearance count, and last-seen; the single
fetch adds the speaker's appearances.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* the list tool returns
live (non-deleted, non-delisted) speakers; the get tool returns one speaker and its appearance list.

### PT-P6-R5 · Functional · Introduce — Speaker-management tools with retroactive rewrite

Thin tools mutate the speaker library — rename, merge, split, the inverses unmerge and unsplit, and
delete/delist with their inverses — one tool per operation. Each edit drives the same retroactive
rewrite of the affected `final.md` files and metadata and emits the same paired events as the in-app
editor (PT-R90); the live transcript is never rewritten. A speaker-library mutation requested while
a recording is in progress is refused, keeping the library read-only during capture (PT-R32).

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* an MCP rename rewrites
the same `final.md` files and emits the same events as a UI rename; a mutation requested during
capture returns a busy error and leaves the library unchanged.

### PT-P6-R6 · Functional · Introduce — Recording-management tools

Tools set a recording's title and request a (re-)refinement of a recording. The refine request
enqueues a job onto the refinement queue and returns immediately rather than blocking on the pass.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* a title-set writes the
recording's title and is reflected in the next listing; a refine request enqueues a job and returns
without waiting for refinement to run.

### PT-P6-R7 · Functional · Introduce — Event query tool

A tool returns recent events, with optional since and type filters, so an agent can confirm the
effect of an operation and observe recording lifecycle without knowing the event log's on-disk
layout.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* after a mutation, the
tool returns the paired event(s); a type filter narrows the returned set.

### PT-P6-R8 · Functional · Introduce — Self-describing discovery and operations manual

Every tool carries a description and an input schema discoverable through `tools/list`, and a manual
tool returns a standalone operations manual covering the data model and the semantics and
reversibility of each operation. The manual describes PulsarTrace on its own terms and names no
external program, service, or workflow.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* `tools/list` carries
descriptions and schemas for every tool; the manual tool returns the manual; the manual references
no external system.

### PT-P6-R9 · Technical · Introduce — Shared speaker-edit orchestration service

The library mutation, the retroactive `final.md` rewrite, and the paired-event emission are one
reusable engine service. The menubar editor, the MCP server, and the CLI `speakers` command all
invoke it, replacing the orchestration previously inlined in the menubar view model; the CLI thereby
gains the retroactive rewrite it previously skipped.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* the menubar editor,
the MCP tools, and the CLI rename all call one service and produce identical file and event effects;
no speaker-edit orchestration remains inlined in the view model.

### PT-P6-R10 · Constraint · Introduce — The agent surface excludes settings, capture control, and content

The MCP surface manages speaker identity and recordings and observes state. It does not change
settings or model selection, does not start or stop capture, and does not transit audio or
transcript content; content is reached only by the filesystem paths the query tools return.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* no tool mutates
settings or model choice; no tool starts or stops capture; no tool returns transcript or audio
content.

### PT-P6-R11 · Functional · Introduce — Server health, supervision, and manual restart

While enabled, the in-process server is supervised: a listener that fails is rebuilt automatically
with bounded backoff, and a bind that keeps failing (for example, the port is taken) stops and
surfaces the error rather than rotating to another port. The server answers an unauthenticated
loopback health probe reporting its status, and Settings shows the live server status and offers a
manual restart.

*Introduces:* one new product requirement, minted at close-out. *Acceptance:* a failed listener is
rebuilt automatically; the health probe returns the server's status over the loopback; Settings
reflects running / down / port-in-use and a manual restart stops and restarts the server.
