---
name: pulsartrace-docs
description: Documentation standards for PulsarTrace. Use whenever creating, editing, reviewing, or reorganizing any Markdown documentation in this repo — the docs/ tree, README, CONTRIBUTING, the overview/component pages, the reference contracts, the docs/specs WIP area — or when deciding where a piece of information belongs. Enforces the what/why/evolution page structure, the one-home-per-fact rule, and the boundary between settled repo docs and forward-looking specs.
---

# PulsarTrace Documentation

How documentation is structured in this repo, and where any given fact belongs.
Load this before creating, editing, moving, or reviewing any Markdown doc.

The goal: documentation that says **what the application is**, **why it is that
way**, and **what changed over time** — without duplicating code, and without
rotting the way a forward-looking PRD does.

## Two zones, split by time

Documentation lives in two zones, divided by tense:

- **Forward zone — `docs/specs/` (and, later, an issue tracker).** What we
  intend to build, design decisions under discussion, implementation plans.
  This churns.
- **Settled zone — the rest of `docs/`.** What the application *is* today, why
  it is shaped that way, and its evolutionary scars. Present tense. Stable.

**Handoff rule:** a decision is not "done" when its code merges — it is done
when its durable residue has landed in the settled-zone docs. The forward zone
holds the deliberation; the settled docs hold the outcome. When you change an
architectural approach, updating the relevant settled `docs/` page is part of
that change, not a follow-up.

## One home per fact

Every kind of fact has exactly one home. Docs link to each other; they never
restate.

| Fact | Home |
|---|---|
| How a user runs it | `README.md` |
| How a contributor builds & tests it | `CONTRIBUTING.md` |
| What the system is / how it's shaped | `docs/overview.md` + component pages |
| The public data contracts | `docs/reference/*` |
| Why a decision was made | the relevant component page (`Why` / `Evolution`) |
| What changed when | `CHANGELOG.md` |
| What a function does in detail | the code + its doc comments |
| What we intend to build next | `docs/specs/` (forward zone) |

Before writing a fact, find its one home. If two homes seem plausible, pick one
and link from the other.

## The docs/ tree

```
docs/
  overview.md          the hub — what PulsarTrace is, the two-pass model,
                       the targets map, the hard invariants, the system diagram
  capture.md           AudioFrameSource, device capture, converters, IPC sockets
  transcription.md     whisper.cpp, FFI, model store, hallucination filtering
  diarization.md       pyannote, the Swift/Python split, the subprocess contract
  speaker-library.md   SQLite, identity model, centroids, reconciliation
  streaming.md         the live pass — LiveRunner, agreement, dedup, resilience
  reference/
    file-format.md     the live.md / final.md contract
    events-schema.md   the JSONL event contract
  specs/               TRANSITIONAL forward zone — design specs & plans.
                       See "The docs/specs/ area" below.
```

`overview.md` is the single front door — the hub. Component pages are spokes;
each names the `Sources/` directories it covers, and the seams mirror
`Sources/PulsarTraceEngine/`'s subdirectories so drift is easy to spot. Keep the
set small (~6 component pages). A swarm of tiny docs is its own "built on the
side" smell — resist splitting finer.

**Migration in progress.** `project-docs/PRD.md` (intent), `DECISIONS.md`
(deviations), and `PLAN.md` (status) predate this structure. They are being
dissolved into the tree above: the PRD freezes as history, each `DECISIONS.md`
entry becomes What/Why/Evolution content on a component page, `PLAN.md` is
retired. Where a settled `docs/` page and an old doc disagree, `docs/` wins.

## The docs/specs/ area (transitional)

Until PulsarTrace adopts an issue tracker, forward-zone artifacts — design specs
(from `pulsartrace-brainstorming`) and implementation plans (from
`pulsartrace-writing-plans`) — live in `docs/specs/`. This is a deliberate
work-in-progress compromise, not part of the settled documentation. When a
tracker is adopted, `docs/specs/` is retired wholesale and this section deleted.

Rules that keep it from contaminating the settled docs:

- **One-way isolation.** A spec or plan MAY link to settled docs. A settled doc
  — `overview.md`, any component page, `reference/*`, `README.md` — MUST NOT
  link to anything under `docs/specs/`. The settled set stays internally
  consistent and complete on its own, with no dangling references when
  `docs/specs/` is eventually removed.
- `docs/specs/` is forward zone: intent and process, not present-tense truth.
  It is **exempt** from the What/Why/Evolution page structure below.
- Filenames: `YYYY-MM-DD-<topic>-design.md` for specs,
  `YYYY-MM-DD-<feature>-plan.md` for plans.

## Page structure: What / Why / Evolution

Every settled component page has the same three layers:

```
# <Component>

## What it is        Present tense. The shape, boundaries, contracts.
## Why it's this way  Rationale for choices a reader would otherwise question.
## Evolution          ONLY where today's shape replaced a past one.
```

The **Evolution** section is strict. Add a note **only when the code actually
changed over time in a way that makes the current state look more complex than
necessary.** Its single job is to answer a future contributor who thinks *"this
looks needlessly complicated — can I simplify it?"* with: "No — here is the
simpler thing we used to do, and here is why it broke."

This is a Chesterton's Fence note. It is NOT a log of every decision, and NOT a
place for "alternatives we considered but never built" — speculation rots. If an
approach was chosen once and simply stuck, it gets no Evolution note; it is
stated present-tense under What / Why.

Test before adding an Evolution note: *Did the repo actually contain a simpler
or different version of this, and would a competent contributor try to revert to
it?* If either answer is no, don't write the note.

## Reference docs are a different genre

`docs/reference/*` documents the three public contracts (`live.md`, `final.md`,
`events/*.jsonl`). Reference pages are terse, present-tense, and exhaustive.
They carry **no Evolution section** — a contract has no history, only versions.
Breaking changes are governed by the SemVer / per-event `version` rules inside
the contract itself, not by prose about the past.

## Never restate code

A doc describes what is true **across multiple files** — boundaries, data flow,
invariants, the *why* of a shape. Anything true of a single file belongs in that
file's doc comment, not in `docs/`. Docs link *down* to code; they never
paraphrase it. If a doc paragraph would need editing every time a function body
changes, it is in the wrong place.

## What never goes in the settled docs/

- **Future intent / "what we want to build."** That goes in `docs/specs/` (see
  above), never in a settled page.
- **Status snapshots** — epic-by-epic progress, "as of <date>" state,
  roadmaps-with-checkboxes. The README capability table and `CHANGELOG.md`
  cover this.
- **Resolved-bug task briefs.** The fix is in git history and the commit
  message. If the root cause is instructive, distil it into one Evolution note
  or a code comment — do not keep the brief.
- **Speculative "alternatives considered."** See the Evolution criterion.
- **Internal tracker shorthand** — `D7`, `R36`, epic numbers. Docs (and code
  comments) name features and files, not requirement/decision IDs.

## Watch for

1. Writing an Evolution note for a decision that never had a prior version — it
   is just What / Why.
2. Adding a new top-level doc when the fact belongs on an existing component
   page.
3. Restating what a function does — that is a doc comment's job.
4. A settled page linking into `docs/specs/` — breaks one-way isolation.
5. Recreating `PLAN.md` / `PREWORK.md` — a status snapshot in any new form.
6. Letting `overview.md` and a component page describe the same mechanism at
   the same depth. Overview is the map; the component page is the territory.
7. Carrying epic / `D##` / `R##` references into doc or comment prose.
