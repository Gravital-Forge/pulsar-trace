---
name: pulsartrace-writing-plans
description: Use when you have an approved Erratum design (a Project PRD or epic intent) to decompose into epics and fully detailed tasks, before touching code
---

# Writing Plans

## Overview

Decompose an approved design into Erratum epics and tasks with enough detail that an engineer who has zero context for the codebase and questionable taste can execute each task correctly. Document everything they need: which files to touch, the code, how to test it, which docs to check. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer who knows almost nothing about this toolset or problem domain, and doesn't know good test design very well.

**Announce at start:** "I'm using the pulsartrace-writing-plans skill to plan the implementation."

**Load the `erratum` skill.** It is the operating manual for the epic and task artifacts you write under `.erratum/`. Derive every ID by its rules, write each epic spec against Project Requirement IDs, and follow its templates so structure stays consistent. You are the doc-owner.

**Context:** If working in an isolated worktree, it should have been created via the `pulsartrace-using-git-worktrees` skill at execution time.

## Where the plan lives

The plan *is* the Erratum epic structure under the open project. Nothing lives outside `.erratum/`.

For each epic, under `.erratum/projects/P<n>-<slug>/epics/E<e>-<slug>/`:

- **`spec.md`** — the epic Specification: an **Intent** written against the Project Requirement IDs and Component IDs it implements, the epic's **Acceptance criteria**, and a **Tasks** list naming each task ID with a one-line description.
- **`tasks/T<t>.md`** — one file per task, carrying the full implementation detail: the files it touches and the bite-sized TDD steps with real code and exact commands. This is where planning depth lives.

A single project may need several epics; each epic produces working, testable software on its own. The product layer is untouched until project close-out.

## Scope Check

If the design covers multiple independent subsystems, split it into multiple epics — one per subsystem — each producing working, testable software on its own. If it is large enough to be several independent initiatives, that is a decomposition into separate projects and belongs back in pulsartrace-brainstorming.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing code, follow established patterns. If the codebase uses large files, don't unilaterally restructure — but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" — step
- "Run it to make sure it fails" — step
- "Implement the minimal code to make the test pass" — step
- "Run the tests and make sure they pass" — step
- "Commit" — step

## Epic Specification

**Every epic `spec.md` starts with this structure:**

```markdown
# PT-P<n>-E<e> · [Epic name] — Specification

**Status:** Open · **Opened:** YYYY-MM-DD

## Intent

Implements PT-P<n>-R3 and PT-P<n>-R4; touches component PT-C2. [2-3 sentences on the approach.]

## Acceptance criteria

- [Concrete, checkable outcomes for the whole epic.]

## Tasks

- PT-P<n>-E<e>-T1 — [short description]
- PT-P<n>-E<e>-T2 — [short description]
```

For a revision of a closed epic, add a `**revises:** PT-P<n>-E<e>-rev<k-1>` line under the status and follow the `erratum` skill's revision rules.

## Task File Structure

**Every `tasks/T<t>.md` carries the depth:**

````markdown
# PT-P<n>-E<e>-T<t> · [Task name]

**Epic:** PT-P<n>-E<e>

## Acceptance criteria

- [What must be true for this task to be done.]

## Files
- Create: `Sources/Exact/Path/File.swift`
- Modify: `Sources/Exact/Path/Existing.swift:123-145`
- Test: `Tests/Exact/Path/FileTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func specificBehavior() {
    let result = subject.compute(input)
    #expect(result == expected)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileTests` (bare, with dangerouslyDisableSandbox — see CLAUDE.md)
Expected: FAIL — `compute` not defined

- [ ] **Step 3: Write minimal implementation**

```swift
// PT-P<n>-R<m>
func compute(_ input: Input) -> Output {
    expected
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FileTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Exact/Path/File.swift Tests/Exact/Path/FileTests.swift
git commit -m "feat: add specific behavior (PT-P<n>-R<m>)"
```
````

Code that implements a task carries the satisfying Project Requirement ID in a comment (`// PT-P<n>-R<m>`), so the binding is recoverable by grep. Close-out re-points these to the product requirement ID.

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Remember
- Exact file paths always
- Complete code in every step — if a step changes code, show the code
- Exact commands with expected output
- Code links carry the Project Requirement ID (`// PT-P<n>-R<m>`)
- DRY, YAGNI, TDD, frequent commits

## Self-Review

After writing the complete epic spec and its task files, look at the design with fresh eyes and check the plan against it. This is a checklist you run yourself — not a subagent dispatch.

**1. Requirement coverage:** For each Project Requirement the epic claims to implement, can you point to a task that delivers it? List any gaps.

**2. Placeholder scan:** Search your task files for red flags — any of the patterns from the "No Placeholders" section above. Fix them.

**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in T3 but `clearFullLayers()` in T7 is a bug.

If you find issues, fix them inline. No need to re-review — just fix and move on. If you find a Project Requirement with no task, add the task.

## Execution Handoff

After writing the epic spec and task files, offer execution choice:

**"Epic PT-P<n>-E<e> planned: spec and tasks written under `.erratum/projects/P<n>-<slug>/epics/E<e>-<slug>/`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using pulsartrace-executing-plans, batch execution with checkpoints

**Which approach?"**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use pulsartrace-subagent-driven-development
- Fresh subagent per task + two-stage review

**If Inline Execution chosen:**
- **REQUIRED SUB-SKILL:** Use pulsartrace-executing-plans
- Batch execution with checkpoints for review

---

## Attribution

Adapted from the `writing-plans` skill in [Superpowers](https://github.com/obra/superpowers) by Jesse Vincent, MIT-licensed. Modified for the PulsarTrace project — see `ATTRIBUTION.md` in the skills directory for the full license text and the list of changes.
