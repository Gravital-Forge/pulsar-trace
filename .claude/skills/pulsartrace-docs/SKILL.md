---
name: pulsartrace-docs
description: Documentation standards for PulsarTrace. Use whenever creating, editing, reviewing, or reorganizing Markdown documentation in this repo — the `.erratum/` layer, the end-user `docs/` tree, the README — or when deciding where a piece of information belongs. Enforces the boundary between the internal Erratum source of truth and the end-user docs, the one-home-per-fact rule, the Erratum-ID code-link convention, and never restating code.
---

# PulsarTrace Documentation

How documentation is structured in this repo, and where any given fact belongs.
Load this before creating, editing, moving, or reviewing any Markdown doc.

PulsarTrace's documentation has two homes, split by audience:

- **`.erratum/` — the internal source of truth.** Product requirements, the
  as-built architecture (including the normative public-output contracts),
  per-project PRDs and decision logs, and the traceability matrix. It is
  maintained per the **Erratum framework — load the `erratum` skill before
  touching anything under `.erratum/`.** You are the doc-owner; subagents never
  write to it.
- **`docs/` + `README.md` — end-user & operational.** What a user or integrator
  needs: how to run it, the public file/event formats, contributor setup,
  release/QA procedures. Present tense; no internal design rationale (that lives
  in `.erratum/`).

## One home per fact

Every kind of fact has exactly one home. Docs link to each other; they never
restate.

| Fact | Home |
|---|---|
| What the product must do (requirements) | `.erratum/product/requirements.md` |
| How the system is shaped (as-built components) | `.erratum/product/architecture/` |
| Why a decision was made | the owning project's `.erratum/projects/<P>/decisions.md` |
| How a requirement traces to its implementation | `.erratum/product/traceability.md` + `// PT-R…` code links |
| The normative public data contracts | `.erratum/product/architecture/transcript-format.md` (PT-C11), `events-log.md` (PT-C6) |
| How a user runs it | `README.md` |
| How a contributor builds & tests it | `CLAUDE.md` (agent/build rules) + `docs/development.md` (host & hardware tests) |
| Operational runbooks / QA | `docs/release-smoke-test.md`, `docs/qa/` |
| What changed when | `CHANGELOG.md` / git history |
| What a function does in detail | the code + its doc comments |

The public output contracts live **only** in `.erratum/product/architecture/`
(`transcript-format.md` = PT-C11, `events-log.md` = PT-C6). Don't re-create a
`docs/` copy or a redirect stub — code, tests, and the README link straight to
the `.erratum/` contract.

## Code links carry Erratum IDs

In-code references to the requirement or decision a piece of code satisfies are
recoverable-by-grep **Erratum IDs** in a comment: `// PT-R36`, `// PT-P5-D1`.
This is how requirement→implementation traceability works — there is no stored
index, only the matrix plus these links. Use the **product** requirement ID
(`PT-R…`) for shipped code; within an open project use that project's requirement
ID until close-out re-points it. Never reintroduce the retired bare `R##`/`D##`
scheme — those IDs referenced the now-retired standalone specs.

## Never restate code

A doc describes what is true **across multiple files** — boundaries, data flow,
invariants, the *why* of a shape. Anything true of a single file belongs in that
file's doc comment, not in a doc. Docs link *down* to code; they never paraphrase
it. If a doc paragraph would need editing every time a function body changes, it
is in the wrong place.

## What never goes in the end-user `docs/`

- **Internal design rationale, requirements, or decisions.** Those live in
  `.erratum/` (the project decision logs and the architecture pages).
- **Status snapshots** — progress, "as of <date>" state, roadmaps with
  checkboxes. The README capability table and `CHANGELOG.md` cover user-facing
  status.
- **Resolved-bug task briefs.** The fix is in git history and the commit
  message; if the root cause is instructive, distil it into the owning project's
  decision log, not an end-user doc.

## Watch for

1. Re-growing a public-contract spec inside `docs/` instead of keeping the
   pointer to `.erratum/product/architecture/`.
2. Putting design rationale in an end-user doc instead of the project decision
   log.
3. Restating what a function does — that is a doc comment's job.
4. Adding a new top-level `docs/` page when the fact belongs in `.erratum/`
   (internal) or on an existing page.
5. Reintroducing bare `R##` / `D##` references — code links and docs use Erratum
   IDs (`PT-R…`, `PT-P…-D…`).
6. Editing a frozen Erratum artifact in place — corrections are `-revN` sibling
   epics; the product layer changes only at project close-out (see the `erratum`
   skill).
