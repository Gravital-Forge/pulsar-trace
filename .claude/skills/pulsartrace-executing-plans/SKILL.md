---
name: pulsartrace-executing-plans
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
---

# Executing Plans

## Overview

Load plan, review critically, execute all tasks, report when complete.

**Announce at start:** "I'm using the pulsartrace-executing-plans skill to implement this plan."

**Note:** Tell the user that this workflow works much better with access to subagents. The quality of its work will be significantly higher if run on a platform with subagent support (such as Claude Code or Codex). If subagents are available, use pulsartrace-subagent-driven-development instead of this skill.

## The Process

### Step 1: Load and Review Plan
1. Read plan file from `docs/specs/`
2. Review critically - identify any questions or concerns about the plan
3. If concerns: Raise them with the user before starting
4. If no concerns: Create TodoWrite and proceed

### Step 2: Execute Tasks

For each task:
1. Mark as in_progress
2. Follow each step exactly (plan has bite-sized steps)
3. Run verifications as specified
4. Mark as completed

### Step 3: Complete Development

After all tasks complete and verified:
- Announce: "I'm using the pulsartrace-finishing-a-development-branch skill to complete this work."
- **REQUIRED SUB-SKILL:** Use pulsartrace-finishing-a-development-branch
- Follow that skill to verify tests, present options, execute choice

## When to Stop and Ask for Help

**STOP executing immediately when:**
- Hit a blocker (missing dependency, test fails, instruction unclear)
- Plan has critical gaps preventing starting
- You don't understand an instruction
- Verification fails repeatedly

**Ask for clarification rather than guessing.**

## When to Revisit Earlier Steps

**Return to Review (Step 1) when:**
- The user updates the plan based on your feedback
- Fundamental approach needs rethinking

**Don't force through blockers** - stop and ask.

## Remember
- Review plan critically first
- Follow plan steps exactly
- Don't skip verifications
- Reference skills when plan says to
- Stop when blocked, don't guess
- Never start implementation on main/master branch without explicit user consent

## Integration

**Required workflow skills:**
- **pulsartrace-using-git-worktrees** - Ensures isolated workspace (creates one or verifies existing)
- **pulsartrace-writing-plans** - Creates the plan this skill executes
- **pulsartrace-finishing-a-development-branch** - Complete development after all tasks

---

## Attribution

Adapted from the `executing-plans` skill in [Superpowers](https://github.com/obra/superpowers) by Jesse Vincent, MIT-licensed. Modified for the PulsarTrace project — see `ATTRIBUTION.md` in the skills directory for the full license text and the list of changes.
