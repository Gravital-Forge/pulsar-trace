# Documentation Rework — Implementation Plan

> ⚠️ **STATUS: DRAFT — NOT YET REVIEWED WITH A HUMAN.** This plan was written by
> an agent from the conversation that designed the documentation rework. It is
> committed for visibility and revision tracking only — it has **not** been
> reviewed or approved. Before any task in it is executed, an agent MUST walk the
> user through a structured review: confirm the goal and scope, resolve the three
> open decisions near the end, and sanity-check each phase against the current
> codebase. Do not begin Phase 0 work until the user has explicitly approved the
> plan.

**Goal:** Replace PulsarTrace's snapshot-tense documentation (PRD = future intent,
DECISIONS = delta log, PLAN = status snapshot) with a present-tense `docs/` tree
that states what the application *is*, *why* it is shaped that way, and *what
changed over time* — without duplicating code.

**Governing skill:** `pulsartrace-docs` defines the standard (the tree, the
What/Why/Evolution page structure, one-home-per-fact, the `docs/specs/`
boundary). Load it before doing any task in this plan. This plan is a forward-zone
spec — it is exempt from the What/Why/Evolution structure and lives in
`docs/specs/`, which retires when an issue tracker is adopted.

**Approach:** Build the new settled tree first, dissolve the old `project-docs/`
material into it, then retire the originals. Each settled page is written from
the *code as it is today* plus the triaged history — never copied from the PRD.

## Target end state

```
docs/
  overview.md              hub: what PulsarTrace is, two-pass model, targets
                           map, the 8 hard invariants, system diagram, on-disk
                           layout
  capture.md               AudioFrameSource, device capture, converters, IPC
  transcription.md         whisper.cpp, FFI, model store, hallucination filter
  diarization.md           pyannote, the Swift/Python split, subprocess contract
  speaker-library.md       SQLite, identity model, centroids, reconciliation
  streaming.md             the live pass — LiveRunner, agreement, dedup
  reference/
    file-format.md         (moved from docs/file-format.md)
    events-schema.md       (moved from docs/events-schema.md)
  release-smoke-test.md    (stays; linked from CONTRIBUTING.md)
  specs/                   transitional forward zone (this plan lives here)
CONTRIBUTING.md            new — build, test, contribute
CHANGELOG.md               new
README.md                  roadmap de-epic'd; doc links repointed
project-docs/
  history/PRD.md           frozen PRD, marked historical
```

Retired: `project-docs/DECISIONS.md`, `project-docs/PLAN.md`,
`project-docs/PREWORK.md`, `project-docs/BUG-mic-capture-silent.md`.

---

## Phase 0 — Inventory & triage (analysis gate)

Everything else depends on this. Produce a triage table; do not write pages yet.

- [ ] **Task 0.1 — Read the legacy docs in full.** `project-docs/PRD.md`,
  `DECISIONS.md`, `PLAN.md`, `PREWORK.md`, `BUG-mic-capture-silent.md`.
- [ ] **Task 0.2 — Triage every `DECISIONS.md` entry.** For each `D<n>`, decide:
  (a) which target page it lands on, and (b) whether it is **absorbed silently**
  (now just "What it is / Why" — chosen once, stuck) or becomes an **Evolution
  note** (a real before/after a contributor would otherwise try to revert).
  Apply the Evolution test from `pulsartrace-docs`. Record the table in this
  file under a "## D-entry triage" heading so Phase 4 can verify nothing is lost.
- [ ] **Task 0.3 — Triage `PREWORK.md` and `BUG-mic-capture-silent.md`.** Mark
  PREWORK's durable parts (dev-host / sandbox model) for `CONTRIBUTING.md`; mark
  the BUG root cause for a `capture.md` Evolution note. The rest is discarded.

**Verification:** the triage table accounts for every `D<n>` entry and every
section of PREWORK/BUG with an explicit destination or a "discard" mark.

## Phase 1 — Scaffold the settled tree

- [ ] **Task 1.1 — Create `docs/overview.md`.** The hub. Sections: what
  PulsarTrace is (present tense); the two-pass model (live vs refine); the
  targets & boundaries map (4 binaries, 3 libraries — what each owns and is
  forbidden); the `AudioFrameSource` abstraction; the data-flow diagram (reuse
  the README diagram); the Swift/Python split & the two IPC sockets; **the 8
  hard invariants** (currently only in the `pulsartrace-execution` skill — this
  is their proper public home); the on-disk layout table. Link down to component
  pages; do not restate them.
- [ ] **Task 1.2 — Create `docs/specs/README.md`.** A short note: this is the
  transitional forward zone for design specs and implementation plans; settled
  docs never link into it; it retires when a tracker is adopted. (See
  `pulsartrace-docs`.)
- [ ] **Task 1.3 — Move the reference docs.** `git mv docs/file-format.md
  docs/reference/file-format.md` and `git mv docs/events-schema.md
  docs/reference/events-schema.md`. Update every inbound link (README.md,
  `pulsartrace-execution` skill, `docs-lookup` references, any code comments).

**Verification:** `docs/overview.md` exists and stands on its own; no link in it
points into `docs/specs/`; `grep` finds no remaining references to the old
`docs/file-format.md` / `docs/events-schema.md` paths.

## Phase 2 — Component pages

Each page uses the What / Why / Evolution structure, names the `Sources/`
directories it covers, and is written from the current code + the Phase 0
triage — not copied from the PRD.

- [ ] **Task 2.1 — `docs/capture.md`** — `Sources/PulsarTraceCapture/`,
  `PulsarTraceEngine/Audio/`, `PulsarTraceEngine/IPC/`. Fold the
  `BUG-mic-capture-silent.md` root cause in as the page's first Evolution note
  (`downmixableFormat()` rewrites the mic's `UseChannelDescriptions` layout —
  the simpler "convert directly" path produced silence).
- [ ] **Task 2.2 — `docs/transcription.md`** — `PulsarTraceEngine/Transcription/`,
  `Sources/CWhisper/`.
- [ ] **Task 2.3 — `docs/diarization.md`** — `PulsarTraceEngine/Diarization/`,
  `python/pulsartrace-ai/`. Cover the Swift/Python split and the subprocess JSON
  contract.
- [ ] **Task 2.4 — `docs/speaker-library.md`** — `PulsarTraceEngine/SpeakerLibrary/`.
- [ ] **Task 2.5 — `docs/streaming.md`** — `PulsarTraceEngine/Streaming/`,
  `Refinement/`.

For each page, apply the triaged `DECISIONS.md` entries: absorbed entries become
present-tense What/Why prose; Evolution entries become Evolution notes. The
events system is cross-cutting — its design lives in `overview.md`, its contract
in `reference/events-schema.md`; no separate `events.md`.

**Verification:** every component page has What + Why; Evolution sections exist
only where the Phase 0 triage flagged a real before/after; no page paraphrases a
single function (that belongs in a doc comment).

## Phase 3 — Top-level docs

- [ ] **Task 3.1 — Create `CONTRIBUTING.md`.** Build & setup, the test-layer
  table and how to run each layer, the Bash-sandbox build rules (from
  `CLAUDE.md`), the dev-host / sandbox model (durable parts of `PREWORK.md`), and
  a pointer to `docs/release-smoke-test.md`.
- [ ] **Task 3.2 — Create `CHANGELOG.md`.** Keep a Changelog format; seed an
  `Unreleased` section reflecting current state.
- [ ] **Task 3.3 — Rewrite the README Roadmap.** Drop "Epic 7/8/9/10" language —
  describe remaining work as features. Repoint doc links to `docs/reference/*`
  and `docs/overview.md`. Refresh the "Project layout" section if needed.

**Verification:** `CONTRIBUTING.md` lets a new contributor build and test from
zero; the README contains no "Epic N" references.

## Phase 4 — Retire the legacy docs

- [ ] **Task 4.1 — Freeze the PRD.** `git mv project-docs/PRD.md
  project-docs/history/PRD.md`; add a header banner marking it a historical
  snapshot (2026) with a pointer to `docs/overview.md` as the current source of
  truth.
- [ ] **Task 4.2 — Delete `project-docs/DECISIONS.md`** — only after the Phase 0
  triage table confirms every `D<n>` entry was dissolved into a settled page.
- [ ] **Task 4.3 — Delete `project-docs/PLAN.md`, `PREWORK.md`,
  `BUG-mic-capture-silent.md`.**
- [ ] **Task 4.4 — Repoint references.** `CLAUDE.md` and the
  `pulsartrace-execution` skill name `project-docs/PRD.md`, `PLAN.md`,
  `DECISIONS.md`, `PREWORK.md` — update them to the new locations
  (`docs/overview.md`, component pages, `project-docs/history/PRD.md`,
  `CONTRIBUTING.md`).

**Verification:** `grep -rn` across the repo finds no live reference to a
retired file.

## Phase 5 — Verification sweep

- [ ] **Task 5.1 — One-way isolation.** No settled doc (`overview.md`, component
  pages, `reference/*`, `README.md`, `CONTRIBUTING.md`) links into `docs/specs/`.
- [ ] **Task 5.2 — No dangling references** to retired files or old paths.
- [ ] **Task 5.3 — No internal shorthand.** `D##` / `R##` / epic numbers gone
  from doc prose and code comments (coordinate with the in-progress
  epic-reference cleanup).
- [ ] **Task 5.4 — Final review** against `pulsartrace-docs`: the tree is
  complete, each fact has one home, nothing restates code.

---

## Open decisions for the user

1. **PRD freeze location** — this plan assumes `project-docs/history/PRD.md`.
   Alternative: a top-level `archive/`, or delete the PRD entirely (git history
   keeps it). You said you value the intent-vs-built contrast, so freezing wins
   by default — confirm the path.
2. **`docs/release-smoke-test.md`** — kept at `docs/` root, linked from
   `CONTRIBUTING.md`. Alternative: move it under `CONTRIBUTING.md` as a section.
3. **Component page count** — 5 component pages + `overview.md`. If `diarization.md`
   or `capture.md` grows past comfortable size, splitting is reasonable, but
   start with 5.

## Not in scope

CI, `SECURITY.md` / `CODE_OF_CONDUCT.md` / issue templates, the Git-LFS
inconsistency, and the other open-source maturity findings are a separate track —
this plan covers documentation only.
