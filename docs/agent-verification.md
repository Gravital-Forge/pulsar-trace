# Agent-driven verification runbook

An AI agent walks the UI items of the release smoke checklist against a real, isolated PulsarTrace
instance, verifying every action against ground truth — files, events, and the MCP surface — and
writes a per-item report. Advisory pre-release aid; never a merge gate. Items the deterministic UI
suites already cover (marked *(automated: …)* in `release-smoke-test.md`) are skipped here.

## Prerequisites

- An accessibility-tree driver the agent can call. Reference tool: Peekaboo
  (`brew install steipete/tap/peekaboo`, or its MCP server) — `menubar click`, `see`, `click`,
  `type`. Any AX-based equivalent works; screenshot-coordinate driving does not (macOS 15's periodic
  screen-capture re-confirmation breaks unattended runs).
- The built dev app: `scripts/make-dev-app.sh` produces `.build/PulsarTrace.app` — but do NOT open
  it yet; launch happens in "Setup" with the isolation environment.
- Terminal TCC: Accessibility for the tool driving the UI. No capture TCC is needed — the walk
  records via fixture capture.
- Element lookup is by accessibility identifier (`Sources/PulsarTraceMenuBar/A11yID.swift` is the
  full list); display text is a fallback for elements the identifiers do not cover.

## Setup (isolation — do not skip)

1. **Quit the daily PulsarTrace instance** (two identical status items are ambiguous to AX
   targeting).

2. Export the isolated environment, then launch the dev app from that shell:

   ```
   export PULSARTRACE_HOME="$(mktemp -d)/pt-agent-home"
   export PULSARTRACE_DEFAULTS_SUITE="com.gravitalforge.PulsarTrace.agent-$(date +%s)"
   export PULSARTRACE_MODELS_DIR="$HOME/Library/Caches/PulsarTrace/models"
   export PULSARTRACE_SYSTEM_FIXTURE="$PWD/Tests/Fixtures/audio/mic-and-system-paired/system.wav"
   export PULSARTRACE_MIC_FIXTURE="$PWD/Tests/Fixtures/audio/mic-and-system-paired/mic.wav"
   mkdir -p "$PULSARTRACE_HOME"
   open --env "PULSARTRACE_HOME=$PULSARTRACE_HOME" \
        --env "PULSARTRACE_DEFAULTS_SUITE=$PULSARTRACE_DEFAULTS_SUITE" \
        --env "PULSARTRACE_MODELS_DIR=$PULSARTRACE_MODELS_DIR" \
        --env "PULSARTRACE_SYSTEM_FIXTURE=$PULSARTRACE_SYSTEM_FIXTURE" \
        --env "PULSARTRACE_MIC_FIXTURE=$PULSARTRACE_MIC_FIXTURE" \
        .build/PulsarTrace.app
   ```

   Every `--env` must be the full `NAME=value` pair: `open --env NAME` with a bare name sets the
   variable to an **empty string**, which the app treats as *unset* — the instance would launch with
   **no isolation** and touch daily state. (Alternatively launch the binary inside the bundle
   directly — `.build/PulsarTrace.app/Contents/MacOS/pulsartrace-mac &` — which inherits the
   exported variables as-is.)

3. Enable the MCP server for ground-truth reads: Settings pane → MCP toggle on (this instance's own
   isolated token/port; read the connection snippet from Settings). This exercises PT-C22 on the
   isolated instance — never connect to the daily instance's server.

## State preparation

Record once through the UI (status item → record): fixture capture plays ~16 s and self-stops; wait
for `final.md` under `$PULSARTRACE_HOME/Documents/PulsarTrace/<stamp>/`. This one recording is the
material for the transcript, recordings-list, and speaker items.

## Ground-truth channels

- **Files**: `live.md` (`<!-- pulsartrace:live -->`, append-only during recording), `final.md`
  (`<!-- pulsartrace:final -->`), `.bak` siblings after speaker edits.
- **Events**: `$PULSARTRACE_HOME/Library/Application Support/PulsarTrace/events/*.jsonl` — check
  type and causal order (cause before `final_md_rewritten`).
- **MCP** (loopback, bearer token from Settings): `list_recordings`, `get_recording_meta`,
  `list_speakers`, `get_speaker`, `recent_events`, and the `manual` tool for semantics. Use the
  **read** tools only: the walk verifies the UI's effects, so performing an edit through an MCP
  write tool (`rename_speaker`, …) would test the wrong surface.

## The walk

For each item: perform the action via AX; verify via the named channel; record pass/fail + note.

01. **Icon state matrix (idle/recording/refining)** — observe the status item before, during, and
    after a fixture recording. *Ground truth:* the status item's AX label at each phase.
02. **Live popover shows rows in real time** — open the panel during recording. *Ground truth:*
    panel rows grow while `live.md` grows.
03. **Recordings list picks up the finished recording** — open the Recordings pane after refine.
    *Ground truth:* row present AND `list_recordings` shows it refined.
04. **Recording title set** — rename the recording inline (click its row title). *Ground truth:*
    `get_recording_meta` shows the title.
05. **Speaker rename ripples** — rename a speaker in the Speakers pane (context menu). *Ground
    truth:* `final.md` rewritten + `.bak`; `speaker_renamed` then `final_md_rewritten` in
    `recent_events`.
06. **Merge + undo** — merge two speakers, then undo from the toast. *Ground truth:* `list_speakers`
    before/after/undone; transcript restored.
07. **Unrecognize speaker** — "Don't recognize this speaker" + confirm. *Ground truth:* affected
    `final.md` lines become "Unrecognized"; `list_speakers` shows it delisted.
08. **Speaker delete + undo toast** — delete a speaker (one-click), undo from the toast. *Ground
    truth:* `list_speakers` before/after/undone.
09. **Speaker split** — split a speaker from the editor. *Ground truth:* `final.md` labels updated;
    split event in `recent_events`. (Unsplit has no GUI affordance — not walkable.)
10. **Second start rejected** — click record while recording. *Ground truth:* status unchanged; no
    second recording folder.
11. **Crash state + recovery** — `kill -9` the `pulsartrace-engine` process mid-recording. *Ground
    truth:* the status item shows the crashed state; "recover from partial WAV" produces a
    `final.md`.
12. **Moved folder disappears** — move the recording folder out of the output dir. *Ground truth:*
    row gone from the Recordings pane on the next refresh; `list_recordings` no longer shows it.
13. **Empty states** — fresh second home (repeat Setup without recording). *Ground truth:* the
    Recordings and Speakers panes show their empty states.

Add any further unmarked UI items from the current checklist that AX can reach. Skip *(automated)*
rows, and record as **not walkable** (with the reason) the items an agent cannot verify: hardware/OS
flows (TCC prompts, Gatekeeper, DMG upgrade, sleep/wake, mic unplug), the global hotkey (needs a
system-wide key event from another app's focus), notifications (bundled `.app` + Notification
Center), play-sample audio output, and purely visual judgements (row styling, spinner, toast
auto-dismiss timing).

## Report

Write `agent-verification-report-<date>.md` next to nothing in the repo — deliver it in the
conversation or a gist, not a commit:

```
# Agent verification — <date>, <branch/commit>
| # | Item | Result | Evidence |
|---|------|--------|----------|
| 1 | Icon state matrix | PASS | AX labels: idle→recording→refining… |
…
Summary: N pass / M fail / K not-walkable. Failures first, each with its evidence.
```

## Teardown

Quit the instance; `rm -rf` the temp home; relaunch the daily app if it was running.
