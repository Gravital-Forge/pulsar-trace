---
name: pulsartrace-doc-sync
description: End-of-development documentation sync for PulsarTrace. Use when wrapping up a development task — before closing or merging a branch, or finalizing a set of changes — to review what the code changes did and bring the docs/ tree, README, and CHANGELOG back in step. Applies the standards defined by the pulsartrace-docs skill. Invoked by pulsartrace-finishing-a-development-branch before integration.
---

# PulsarTrace Doc Sync

Run at the end of a development task — before closing a branch or finalizing a
change — to bring documentation back in step with the code that changed. This is
how the docs stay current: every change ends with a doc-sync pass.

This skill is the **procedure**. The **standard** it applies — the `docs/` tree,
page structure, where each fact lives, when an Evolution note is warranted — is
defined by the **`pulsartrace-docs`** skill. Load that skill alongside this one;
this skill defers to it for every "how" and "where" question and never restates
its rules.

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
effect: new capabilities, changed behaviour, **an approach that was replaced**,
public-contract changes (`live.md` / `final.md` / `events/*.jsonl`), new or
removed dependencies, build/setup changes.

### 2. Map changed code to doc pages

| Changed area | Doc page to check |
|---|---|
| `Sources/PulsarTraceCapture/`, `Audio/`, `IPC/` | `docs/capture.md` |
| `Transcription/` | `docs/transcription.md` |
| `Diarization/`, `python/pulsartrace-ai/` | `docs/diarization.md` |
| `SpeakerLibrary/` | `docs/speaker-library.md` |
| `Streaming/` | `docs/streaming.md` |
| Targets, invariants, system shape | `docs/overview.md` |
| `live.md` / `final.md` / events format | `docs/reference/*` |
| User-facing CLI / install / behaviour | `README.md`, `CHANGELOG.md` |

If a relevant page does not exist yet (the `docs/` tree is mid-migration), do
not skip silently — record it as a gap in the report.

### 3. Classify each needed update

For every affected page, decide which layer changed (`pulsartrace-docs` defines
the What / Why / Evolution structure):

- **New capability** → update **What it is**, present tense.
- **Changed rationale** → update **Why it's this way**.
- **An approach was replaced** → run the Evolution test from `pulsartrace-docs`:
  did the repo actually contain a simpler/different prior version, and would a
  competent contributor try to revert to it? Closing a branch is the moment the
  before/after is in hand and has not yet evaporated — if the test passes, write
  the **Evolution** note now. If it fails, it is just a What/Why update.
- **Public contract changed** → update `docs/reference/*`, and confirm the
  SemVer / per-event `version` rules in the contract were honoured.
- **User-visible behaviour changed** → update the README capability table and
  add a `CHANGELOG.md` entry.

### 4. Apply updates

Make the clear-cut updates directly, following `pulsartrace-docs`. For genuine
judgment calls — an ambiguous Evolution note, a fact with two plausible homes, a
missing page that needs creating — describe the call and ask rather than guess.

### 5. Report

Close with three lists:

- **Updated** — pages changed, one line each on what and why.
- **Checked, no change needed** — pages reviewed and confirmed still accurate.
- **Deferred** — anything that belongs in the forward zone, not a settled page
  (future intent, follow-up work → `docs/specs/`), and any doc-tree gaps found
  in step 2.

## Don't

- Don't restate the `pulsartrace-docs` rules here — defer to that skill.
- Don't write an Evolution note for a net-new feature: nothing was replaced.
- Don't touch a doc the change did not affect just to leave a mark.
- Don't document future intent in a settled page — that goes to `docs/specs/`.
- Don't link a settled page into `docs/specs/` — one-way isolation.
- Don't paraphrase a function into a doc — docs describe what is true across
  files.
