# Attribution — adapted skills

Several skills in this directory are **derivative works** adapted from
**Superpowers** by Jesse Vincent — <https://github.com/obra/superpowers>
(v5.1.0) — distributed under the MIT License.

## Derivative skills

| PulsarTrace skill | Adapted from Superpowers skill |
|---|---|
| `pulsartrace-brainstorming` | `brainstorming` |
| `pulsartrace-writing-plans` | `writing-plans` |
| `pulsartrace-executing-plans` | `executing-plans` |
| `pulsartrace-subagent-driven-development` | `subagent-driven-development` |
| `pulsartrace-tdd` | `test-driven-development` |
| `pulsartrace-systematic-debugging` | `systematic-debugging` |
| `pulsartrace-requesting-code-review` | `requesting-code-review` |
| `pulsartrace-receiving-code-review` | `receiving-code-review` |
| `pulsartrace-verification-before-completion` | `verification-before-completion` |
| `pulsartrace-using-git-worktrees` | `using-git-worktrees` |
| `pulsartrace-finishing-a-development-branch` | `finishing-a-development-branch` |

`pulsartrace-docs` and `pulsartrace-doc-sync` are original PulsarTrace work and
are not derived from Superpowers.

## Modifications made

Common to all adapted skills:

- Renamed into the `pulsartrace-` namespace; all cross-skill references updated.
- "your human partner" rephrased to "the user" / "the human" for consistency
  with the rest of the PulsarTrace skill set.
- Marketplace/plugin plumbing removed (no `using-superpowers` bootstrap, no
  `superpowers:` plugin prefixes).

Skill-specific:

- `pulsartrace-tdd` — merges the Superpowers `test-driven-development` discipline
  with PulsarTrace's own test-layer / determinism / snapshot rules.
- `pulsartrace-brainstorming` — the browser-based "Visual Companion" removed
  (PulsarTrace is not a web app); the absolute "no code before approved design"
  hard-gate removed (brainstorming is the design step for substantial work, not
  a universal blocker); the approved design is captured in the Erratum layer as
  a Project PRD or epic intent (see `pulsartrace-docs` and the `erratum` skill).
- `pulsartrace-writing-plans` / `-executing-plans` / `-subagent-driven-development`
  — plans are authored as Erratum epics and tasks (epic `spec.md` plus
  `tasks/T*.md`) under the open project, with code links carrying Project
  Requirement IDs; reviewer dispatch points at the project's existing
  `.claude/agents/` (`code-reviewer`, `swift-reviewer`, `python-reviewer`)
  instead of generic prompt-template files.
- `pulsartrace-receiving-code-review` — the "Strange things are afoot at the
  Circle K" safe-phrase removed.
- `pulsartrace-finishing-a-development-branch` — adds a mandatory Erratum epic
  close (and project close-out when the project's last epic closes) plus a
  documentation sync (`pulsartrace-doc-sync`) before integration; makes "never
  remove the worktree when a PR is opened" an explicit red flag.

## Superpowers MIT License

```
MIT License

Copyright (c) 2025 Jesse Vincent

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
