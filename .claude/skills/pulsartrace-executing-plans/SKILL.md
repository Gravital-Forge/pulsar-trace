---
name: pulsartrace-executing-plans
description: Use when you have a planned Erratum epic to execute in a separate session with review checkpoints
---

# Executing Plans

## Overview

Load the epic, review critically, execute all its tasks, report when complete.

**Announce at start:** "I'm using the pulsartrace-executing-plans skill to implement this epic."

**Load the `erratum` skill.** You are the doc-owner: as the epic completes you write its Completion Record, and code you write carries the Project Requirement code link. The `erratum` skill defines those mechanics.

**Note:** This workflow works much better with access to subagents. If subagents are available, use pulsartrace-subagent-driven-development instead of this skill.

## The Process

### Step 1: Load and Review the Epic
1. Read the epic `spec.md` and its `tasks/T<t>.md` files under `.erratum/projects/P<n>-<slug>/epics/E<e>-<slug>/`
2. Review critically — identify any questions or concerns about the plan
3. If concerns: raise them with the user before starting
4. If no concerns: create TodoWrite from the task list and proceed

### Step 2: Execute Tasks

For each task:
1. Mark as in_progress
2. Follow each step exactly (the task file has bite-sized steps)
3. Run verifications as specified
4. Code you write carries its Project Requirement code link (`// PT-P<n>-R<m>`)
5. Mark as completed

### Step 3: Complete Development

After all tasks complete and verified:
- Announce: "I'm using the pulsartrace-finishing-a-development-branch skill to complete this work."
- **REQUIRED SUB-SKILL:** Use pulsartrace-finishing-a-development-branch
- Follow that skill to verify tests, write the Epic Completion Record, reconcile at close-out when the project is done, present options, execute choice

## When to Stop and Ask for Help

**STOP executing immediately when:**
- Hit a blocker (missing dependency, test fails, instruction unclear)
- A task has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- The user updates the epic based on your feedback
- Fundamental approach needs rethinking

A gap discovered while the epic is open is fixed by editing its spec or adding a task — fine. **Don't force through blockers** — stop and ask.

## Remember
- Review the epic critically first
- Follow task steps exactly
- Don't skip verifications
- Code links carry the Project Requirement ID (`// PT-P<n>-R<m>`)
- Reference skills when a task says to
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow skills:**
- **pulsartrace-using-git-worktrees** — Ensures isolated workspace (creates one or verifies existing)
- **pulsartrace-writing-plans** — Plans the epic this skill executes
- **pulsartrace-finishing-a-development-branch** — Complete development after all tasks

---

## Attribution

Adapted from the `executing-plans` skill in [Superpowers](https://github.com/obra/superpowers) by Jesse Vincent, MIT-licensed. Modified for the PulsarTrace project — see `ATTRIBUTION.md` in the skills directory for the full license text and the list of changes.
