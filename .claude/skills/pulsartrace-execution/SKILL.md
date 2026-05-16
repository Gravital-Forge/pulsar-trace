---
name: pulsartrace-execution
description: Guide the implementation of the PulsarTrace local-only Mac meeting transcription app. Use this skill whenever working on the PulsarTrace codebase, reading or updating its PRD, planning or executing an epic, writing or reviewing Swift/Python code in any of its targets (pulsartrace-engine, pulsartrace-capture, pulsartrace-mac, pulsartrace-ai), running its test suite, or designing changes to its three public API surfaces (live.md, final.md, events/*.jsonl). Activate even when PulsarTrace is mentioned only in passing — this project has strict architectural invariants and a specific milestone structure that this skill enforces. Reach for this skill before writing any code that touches audio capture, transcription, diarization, the speaker library, the events log, or the IPC layer.
---

# PulsarTrace Execution

This skill orients the implementing agent to PulsarTrace's specific architecture, invariants, and milestone structure. The PRD is the source of truth; this skill is the daily-driver reminder of what matters most.

## Where to find things

The canonical documents:

- `project-docs/PRD.md` — the full PRD; sections 8 (Requirements), 14 (GTM), and 15 (Epic Breakdown) are most referenced during implementation
- `project-docs/PLAN.md` — checkpointed implementation plan (epic-by-epic status)
- `project-docs/DECISIONS.md` — architectural decisions / deviations from the PRD (D1, D2, …)
- `docs/file-format.md` — `live.md` / `final.md` format spec (referenced by R13, R35–R39)
- `docs/events-schema.md` — JSONL events log schema (referenced by §8.13, R78–R86)
- `docs/release-smoke-test.md` — manual smoke-test checklist (R69)

Always read the relevant section of the PRD before starting work on an epic. The PRD's `Edge cases owned` blocks per epic tell you what failure modes you're responsible for in this slice of work.

## What we're building (in one paragraph)

A local-only macOS 14+ app that records meetings, transcribes them with whisper.cpp, diarizes them with pyannote/diart, and writes speaker-labeled markdown files plus a JSONL events log. Users plug their own AI agent into the files — there is no in-app LLM. Open source, MIT, no telemetry, no auto-update, no App Store, no sandboxing for v1. Two-pass model: live (provisional, for in-call agent use) and post-call refinement (offline-quality, the source of truth).

## The architecture in one diagram

```
AudioFrameSource (protocol)            ┌─────────────────────────┐
   • DeviceCaptureSource ────────────► │                         │
   • FixturePlaybackSource (tests)    │  pulsartrace-engine      │ ──► live.md
   • PipeSource (CLI integration)  ──► │  - whisper streaming     │ ──► final.md
   • SocketSource (capture daemon)    │  - diart (sys stream)    │ ──► events/*.jsonl
                                       │  - speaker library lookup│
                                       └─────────────────────────┘
```

`AudioFrameSource` is **the** central abstraction. Engine code never knows whether bytes came from a real device or a fixture WAV. This is what makes nine of the ten epics testable on hardware without working audio.

## Milestones

- **v0.1 (Epics 1–5)** — Offline CLI: `pulsartrace refine path/to/audio.wav` → `final.md` with speaker labels. Ship-able on its own. Develop-able on EC2 Mac / Tart VM / any Mac (no real audio needed).
- **v1.0 (Epics 6–10)** — Adds streaming, real device capture, menubar UI, distribution. Real audio devices needed for Epic 7 only.

Always know which milestone you're in and whether the current change belongs in v0.1 or v1.0. Live-mode features in an offline epic, or UI features in v0.1, are scope creep.

## Hard invariants (NEVER violate)

These are non-negotiable. If a change would violate one, stop and ask the human.

1. **No telemetry, ever.** No analytics, no error reporting that phones home, no version-check pings. The only outbound network calls are first-launch model downloads from known hosts (Hugging Face, OpenAI's whisper.cpp bucket).
2. **No in-app LLM features.** No summarization, no chat, no "ask your meetings." The whole point is users plug their own agent in.
3. **AudioFrameSource is the only audio interface.** Engine code that calls `AVAudioEngine` or `SCStream` or `AVAudioFile` directly is a bug, regardless of test pass/fail. All audio enters the engine through a conforming source.
4. **`live.md` is strictly append-only.** No rewrites, no in-place edits, no replacements during a live recording. Speaker renames mid-call apply to the next post-pass, never to the live file. (R36)
5. **Speaker library is read-only during the live pass.** Only post-pass refinement writes to it. This prevents bad live-clustering from polluting the persistent library. (R32)
6. **Speaker IDs (`spk_<ulid>`) are forever stable.** Renames change the `name` field; the `id` never changes. Agents use the ID to track identity across renames.
7. **Never log content.** The operational log (`~/Library/Logs/PulsarTrace/`) never contains audio bytes, transcript text, speaker names, or full user file paths. The events log MAY contain speaker names (user-assigned, local-only) but never audio/transcript content/full paths.
8. **Events come paired with their causes.** A speaker rename emits both `speaker_renamed` AND `final_md_rewritten`. A merge emits `speaker_merged` AND a `final_md_rewritten` per affected recording. Never emit a file change without the cause event that triggered it.

## The three public APIs

External tools (the user's AI agent, scripts, integrations) depend on three contracts. Treat all three as SemVer-stable:

1. **`live.md`** — append-only per-recording transcript stream, marker `<!-- pulsartrace:live -->`, created at session start (R35a) so agents tailing it have a signal even before the first utterance.
2. **`final.md`** — refined per-recording transcript, marker `<!-- pulsartrace:final -->`, atomically replaces `live.md` at end of refinement. The source of truth.
3. **`events/*.jsonl`** — system-wide event log, 30-day retention, daily-rotated. Every significant operation emits exactly one event with stable schema (per-type `version` field).

Breaking changes to any of these require a major version bump and a migration note. Adding a new optional field is non-breaking. Removing a field or changing its type is breaking.

## Two-language reality

- **Swift** — host app, engine, capture daemon, CLI, all tests. ~80% of code.
- **Python** — captive subprocess running pyannote and diart only. Bundled via `python-build-standalone` inside the .app at `Contents/Resources/python/`.

IPC is split into two sockets per session:
- `capture.sock` — binary frame protocol (length-prefixed PCM, 16kHz mono Float32, 20ms framing). `pulsartrace-capture` writes; `pulsartrace-engine` reads via `SocketSource`.
- `control.sock` — JSON-line protocol for engine ↔ UI/CLI control messages.

If you find yourself reaching for a third language, stop. The fewer languages, the better.

## Test discipline

Layer | Speed | When | Devices
---|---|---|---
`swift test --filter Unit` | <5s | Every non-trivial change | None
`swift test --filter Pipeline` | ~30s | Every change to engine logic | None
`swift test --filter Pipeline.IPC` | ~30s | Every change to capture↔engine protocol | None
`swift test --filter Capture` | ~60s | Every change to capture daemon | BlackHole
`pytest python/pulsartrace-ai/` | ~20s | Every change to Python wrapper | None
Manual smoke (`docs/release-smoke-test.md`) | ~5min by human | Before each release tag | Real Mac

Non-negotiable rules:
- **Tests ship with the code that creates them.** No separate "testing epic." If you can't write the test, the code isn't done.
- **Determinism is mandatory.** Seeded RNG, whisper temperature 0, pinned model hashes, fixture audio committed to repo. Without these, snapshot tests flake and you'll be tempted to "fix" the test.
- **Snapshot test failures are not bugs to fix by updating the snapshot.** They indicate a contract change that needs explicit justification. If you're updating a snapshot, ask whether the contract change is intentional. If yes, mention it explicitly in the commit. If no, fix the code, not the snapshot.

## Things LLMs tend to get wrong on this project

Watch for these specifically:

1. **Writing to live.md after creation in any way other than appending.** Updating "Unknown #2" to a name, fixing a typo, anything. Always append-only.
2. **Reading from `~/Library/Application Support/PulsarTrace/speakers.sqlite` during the live pass and treating it as authoritative.** Live reads are for display only; the post-pass is the source of truth for library state.
3. **Calling whisper-cli as a subprocess per chunk.** The model must be resident. One whisper instance per stream, kept alive for the session.
4. **Bundling `pulsartrace-capture` work into Epic 1.** That binary doesn't exist until Epic 7. v0.1 (Epics 1–5) only uses fixture/pipe/socket sources.
5. **Adding telemetry "just for the model download."** Even a `?version=1.0.0` query param on the download URL is telemetry. Don't.
6. **Writing event types with ambiguous timing.** Events MUST be emitted in causal order. `speaker_renamed` BEFORE `final_md_rewritten`, not after.
7. **Treating speaker names as identifiers.** Always use `spk_<ulid>` IDs internally and in events. Names are display strings that can change.
8. **Letting whisper hallucinate "thanks for watching" on silence.** VAD-gate the input. Filter `[BLANK_AUDIO]` from output. (Mentioned in Epic 2 edge cases.)
9. **Storing audio at 48kHz stereo float32.** The canonical storage format is 16kHz mono Int16 PCM WAV (R54e). Resampling/downmixing happens at the capture-source boundary, not at storage time.
10. **Forgetting the `version` field in events.** Every event has `ts`/`type`/`id`/`version`. The `version` lets us evolve schemas per-type without breaking the whole consumer base.

## When in doubt

In order:

1. **Re-read the relevant epic block in the PRD's Section 15.** The "Requirements" and "Edge cases owned" lists tell you what you're responsible for.
2. **Check the file format / events schema docs** if the change touches a public API surface.
3. **Look at how an existing similar feature is structured.** The conventions established in Epic 1 carry through every subsequent epic.
4. **Ask the human** if a change would violate an invariant, or if you're uncertain whether a feature belongs in v0.1 or v1.0.

## Communication style

When reporting on PulsarTrace work, lead with what's done, what's tested, and what events the change emits. Skip flourish. Examples:

✅ "Epic 2 done. R9, R11, R13 covered. Pipeline tests passing on `two-speakers-overlap.wav` fixture. Events `refinement_started`/`completed` wired in but unused at this epic (Epic 4 will use them)."

❌ "I've finished a comprehensive implementation of the offline transcription functionality with full Whisper integration and complete test coverage across multiple test scenarios."

