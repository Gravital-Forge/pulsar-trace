# PT-P5-E2-rev2 · Live-Diarization Wedge Reliability — Specification

**Status:** Frozen · **Opened:** 2026-06-18 · **Closed:** 2026-06-23

**revises:** PT-P5-E2-rev1

## Intent

Find and fix the live-diarization **wedge**: a single `diarizeWindow` call hangs and never returns,
holding the live diarizer's one in-flight slot forever, so every later window is skipped and the
system stream collapses to one speaker. Also fix the §2b **label collapse** where a no-coverage live
utterance silently inherits the first speaker's name. This is a reliability revision of PT-P5-E2's
live diarization; it proposes **no new product requirement** — it hardens the existing live-pass
guarantees (PT-R15/R16, and the wedged-decode isolation intent that PT-P5-R4 carries) rather than
adding one. Touches Live Diarization (PT-C13), the engine record orchestrator's subprocess-pipe
drain (PT-C9), and live system-label resolution (PT-C12/PT-C14).

This was the project's last open work; its resolution merged via PR #12 (`cc3199d`), which keeps
live diarization in-process and fixes the wedge at its real root cause.

## Acceptance criteria

- A single hung diarization window never freezes live diarization for the rest of the session, and
  never starves the live transcription pass.
- Live diarization runs in-process (no diarizer worker subprocess) and the invariant "a wedged
  diarizer never stalls transcription or `live.md`" holds.
- A no-coverage live utterance is labelled with a neutral `Speaker?` marker and skips the R18
  library lookup, so it can never inherit the first speaker's name.

## Tasks

- PT-P5-E2-rev2-T1 — `DiarGate` slot-reclaim with a deadline and a generation token (PT-P5-D6) —
  later found insufficient under a wedge storm.
- PT-P5-E2-rev2-T2 — A killable diarizer **worker subprocess** (`--diarizer-worker`, a per-session
  Unix socket, a length-prefixed wire codec, supervisor with deadline + SIGKILL/respawn) (PT-P5-D7)
  — built to release a "wedged ANE call", later reverted.
- PT-P5-E2-rev2-T3 — Root-cause the wedge (`lldb`/`spindump`): FluidAudio profile logging blocking
  in `write()` on a full, byte-by-byte-drained inherited stderr pipe — not ANE contention. Fix at
  the source: worker stdio → `/dev/null`; chunked `readToEnd()` pipe drain in `RecordOrchestrator`.
- PT-P5-E2-rev2-T4 — Revert the worker entirely; run live diarization in-process via
  `DiarizerEngineRawAdapter` over the resident `DiarizerEngine`; `DiarGate` back to a plain
  ≤1-in-flight gate (PT-P5-D7).
- PT-P5-E2-rev2-T5 — §2b: no-coverage live utterances get the neutral `Speaker?` label and skip the
  R18 lookup (PT-P5-D8).
