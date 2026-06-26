---
name: pulsartrace-doc-sync
description: End-of-development documentation sync for PulsarTrace. Use when wrapping up a development task — before closing or merging a branch, or finalizing a set of changes — to bring the end-user docs/ tree, README, and CHANGELOG back in step with what the code changes did. Applies the standards defined by the pulsartrace-docs skill. Invoked by pulsartrace-finishing-a-development-branch before integration.
---

# PulsarTrace Doc Sync

Run at the end of a development task — before closing a branch or finalizing a
change — to bring the **end-user and operational documentation** back in step
with the code that changed. This is how those docs stay current: every change
ends with a doc-sync pass.

This skill is the **procedure**. The **standard** it applies — the two
documentation homes, the one-home-per-fact rule, where each fact lives — is
defined by the **`pulsartrace-docs`** skill. Load that skill alongside this one;
defer to it for every "how" and "where" question, and never restate its rules.

**Also load the `erratum` skill.** Internal facts — requirements, architecture,
decisions, the public-contract specifications — live in `.erratum/` and move
through the project layer and project close-out, never through this pass. When
this pass surfaces an internal fact, route it there.

## Scope of this pass

This pass touches only the documentation that lives **outside** `.erratum/`:

- `README.md` — how a user runs it; the capability table
- `CHANGELOG.md` — what changed, user-facing
- `docs/development.md` — dev host and build/test setup (with `CLAUDE.md`)
- `docs/release-smoke-test.md`, `docs/qa/` — operational runbooks and QA logs

Requirements, architecture, decisions, and the normative public-output contracts
belong to the Erratum project layer. This pass does not edit them — it hands any
such fact to the Erratum flow (see step 4).

## When to run

- After the code for a task is complete and tested, before the branch is closed
  or merged. `pulsartrace-finishing-a-development-branch` invokes this skill as
  a required step.
- When explicitly asked to "sync the docs" or "update documentation for these
  changes."

Treat it as a required final step, not an optional cleanup.

## Procedure

### 1. Establish the change set

Diff the branch against the base, and include uncommitted work:

```
git diff $(git merge-base main HEAD) HEAD --stat
git diff $(git merge-base main HEAD) HEAD
git status --short
```

Summarise what actually changed, in plain terms — not file-by-file, but by
effect: new capabilities, changed behaviour, public-contract changes
(`live.md` / `final.md` / `events/*.jsonl`), new or removed dependencies,
build/setup changes.

### 2. Map changed code to doc surfaces

| Changed area | Doc surface to check |
|---|---|
| User-facing CLI, install, or behaviour | `README.md` capability table, `CHANGELOG.md` |
| Build, test, host, or dependency setup | `docs/development.md`, `CLAUDE.md` |
| Release or QA procedures | `docs/release-smoke-test.md`, `docs/qa/` |
| Public output contracts (`live.md` / `final.md` / events) | the normative specs in `.erratum/product/architecture/` (`transcript-format.md` = PT-C11, `events-log.md` = PT-C6) — confirm README and code link to them; the spec text itself reconciles through the Erratum project, not here |
| Requirements, architecture, design rationale | the Erratum project layer (PRD, epic spec, decision log) — route via step 4 |

### 3. Apply the user-facing and operational updates

For each affected surface in scope, update it in present tense, describing what
is true now:

- **New capability** → update the README capability table and add a
  `CHANGELOG.md` entry.
- **Changed user-visible behaviour** → update the affected README or operational
  page.
- **Build / setup / dependency change** → update `docs/development.md`.
- **Public contract changed** → confirm README and code link to the `.erratum/`
  contract spec, and that the SemVer / per-event `version` rules were honoured.

Make the clear-cut updates directly, following `pulsartrace-docs`. For genuine
judgment calls — a fact with two plausible homes, a page that needs creating —
describe the call and ask rather than guess.

### 4. Route internal facts to Erratum

If the change carries an internal fact — the reasoning behind a design choice, a
new or changed requirement, an as-built architecture change, a contract spec
change — it does not belong in an end-user doc. Record it where the `erratum`
skill places it: the project **Decision Log** for rationale, the **PRD** /
**epic spec** for requirements and intent, and the product layer at close-out
for architecture and contracts. Note it in the report as routed there.

### 5. Report

Close with three lists:

- **Updated** — surfaces changed, one line each on what and why.
- **Checked, no change needed** — surfaces reviewed and confirmed still accurate.
- **Routed to Erratum** — internal facts handed to the project layer, and any
  gaps found in step 2.

## Don't

- Don't restate the `pulsartrace-docs` rules here — defer to that skill.
- Don't touch a doc the change did not affect just to leave a mark.
- Don't put design rationale, requirements, or decisions in an end-user doc —
  those go to the Erratum project layer (step 4).
- Don't copy a public-contract spec into `docs/` — link to the `.erratum/`
  contract instead.
- Don't paraphrase a function into a doc — docs describe what is true across
  files.
