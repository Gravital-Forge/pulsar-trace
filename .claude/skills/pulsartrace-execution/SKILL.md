---
name: pulsartrace-execution
description: Guide the implementation of the PulsarTrace local-only Mac meeting transcription app. Use this skill whenever working on the PulsarTrace codebase, consulting the Erratum docs (`.erratum/`), planning or executing an initiative, writing or reviewing Swift code in any of its targets (pulsartrace-engine, pulsartrace-capture, pulsartrace-mac, the CLI, and the PulsarTraceEngine/Capture/MenuBar libraries), running its test suite, or designing changes to its three public API surfaces (live.md, final.md, events/*.jsonl). Activate even when PulsarTrace is mentioned only in passing — this project has strict architectural invariants that this skill enforces. Reach for this skill before writing any code that touches audio capture, transcription, diarization, the speaker library, the events log, or the IPC layer.
---

# PulsarTrace Execution

This skill orients the implementing agent to PulsarTrace's specific architecture and invariants. The Erratum layer (`.erratum/`) is the source of truth; this skill is the daily-driver reminder of what matters most.

## Where to find things

The canonical documents all live under `.erratum/`:

- `.erratum/product/requirements.md` — the active product requirements (`PT-R…`)
- `.erratum/product/architecture/` — the as-built components (`index.md`) plus the public output contracts: `transcript-format.md` (PT-C11) and `events-log.md` (PT-C6)
- `.erratum/product/traceability.md` — the matrix linking every requirement to its origin and the work that implemented it
- `.erratum/projects/` — each initiative's PRD (scope + change-typed project requirements) and decision log (`PT-P…-D…`), plus its epics
- `docs/release-smoke-test.md` — manual smoke-test checklist (PT-R69)
- `docs/development.md` — dev host + hardware-dependent test setup

Before starting work, read the relevant product requirements and the project/epic spec under `.erratum/projects/` that owns it. The epic specs record the scope and the failure modes each slice is responsible for. The Erratum framework itself is documented in the `erratum` skill — you are the doc-owner for `.erratum/`; subagents never write to it.

## What we're building (in one paragraph)

A local-only macOS 14+ app that records meetings, transcribes and diarizes them **fully in-process on the Apple Neural Engine**, and writes speaker-labeled markdown files plus a JSONL events log. Users plug their own AI agent into the files — there is no in-app LLM. Open source, MIT, no telemetry, no auto-update, no App Store, no sandboxing for v1. Two-pass model: live (provisional, for in-call agent use) and post-call refinement (offline-quality, the source of truth).

## The architecture in one diagram

```
AudioFrameSource (protocol)            ┌─────────────────────────────┐
   • DeviceCaptureSource ────────────► │                             │
   • FixturePlaybackSource (tests)    │  pulsartrace-engine          │ ──► live.md
   • PipeSource (CLI integration)  ──► │  - Parakeet live (ANE)       │ ──► final.md
   • SocketSource (capture daemon)    │  - WhisperKit refine (ANE)   │ ──► events/*.jsonl
                                       │  - FluidAudio diarize (ANE)  │
                                       │  - speaker library lookup    │
                                       └─────────────────────────────┘
```

`AudioFrameSource` is **the** central abstraction. Engine code never knows whether bytes came from a real device or a fixture WAV — which is what makes the pipeline testable on any Mac without working audio. Transcription (Parakeet TDT v3 live via FluidAudio; WhisperKit on refine), diarization (FluidAudio CoreML), and embeddings all run on the Neural Engine, in-process — there is no Python and no whisper.cpp.

## Project structure

The product is built out and reconciled through Erratum projects **P1–P5** (offline core → real-time & surfaces → resilience & refinement → product polish → Apple Neural Engine migration). Each is frozen in `.erratum/projects/`; the product layer in `.erratum/product/` reflects the current shipped state.

New scope opens a **new Erratum project** (or, for a small correction to closed work, a `-revN` sibling epic). Always know which initiative your change belongs to, and never edit a closed/frozen project or epic in place.

## Hard invariants (NEVER violate)

These are non-negotiable. If a change would violate one, stop and ask the human.

1. **No telemetry, ever.** No analytics, no error reporting that phones home, no version-check pings. The only outbound network calls are first-launch model-bundle downloads from their published hosts (Hugging Face) — never with identifying query params. (PT-R87)
2. **No in-app LLM features.** No summarization, no chat, no "ask your meetings." The whole point is users plug their own agent in.
3. **AudioFrameSource is the only audio interface.** Engine code that calls `AVAudioEngine` or `SCStream` or `AVAudioFile` directly is a bug, regardless of test pass/fail. All audio enters the engine through a conforming source.
4. **`live.md` is strictly append-only.** No rewrites, no in-place edits, no replacements during a live recording. Speaker renames mid-call apply to the next post-pass, never to the live file. (PT-R36)
5. **Speaker library is read-only during the live pass.** Only post-pass refinement writes to it. This prevents bad live-clustering from polluting the persistent library. (PT-R32)
6. **Speaker IDs (`spk_<ulid>`) are forever stable.** Renames change the `name` field; the `id` never changes. Agents use the ID to track identity across renames.
7. **Never log content.** The operational log (`~/Library/Logs/PulsarTrace/`) never contains audio bytes, transcript text, speaker names, or full user file paths. The events log MAY contain speaker names (user-assigned, local-only) but never audio/transcript content/full paths.
8. **Events come paired with their causes.** A speaker rename emits both `speaker_renamed` AND `final_md_rewritten`. A merge emits `speaker_merged` AND a `final_md_rewritten` per affected recording. Never emit a file change without the cause event that triggered it.

## The three public APIs

External tools (the user's AI agent, scripts, integrations) depend on three contracts. Treat all three as SemVer-stable:

1. **`live.md`** — append-only per-recording transcript stream, marker `<!-- pulsartrace:live -->`, created at session start (PT-R35a) so agents tailing it have a signal even before the first utterance.
2. **`final.md`** — refined per-recording transcript, marker `<!-- pulsartrace:final -->`, atomically replaces `live.md` at end of refinement. The source of truth.
3. **`events/*.jsonl`** — system-wide event log, 30-day retention, daily-rotated. Every significant operation emits exactly one event with stable schema (per-type `version` field).

Breaking changes to any of these require a major version bump and a migration note (PT-R89). Adding a new optional field is non-breaking. Removing a field or changing its type is breaking. The normative contracts are `.erratum/product/architecture/transcript-format.md` (PT-C11) and `events-log.md` (PT-C6).

## One-language reality

- **Swift, everywhere** — host app, engine, capture daemon, CLI, all tests. There is no Python: transcription and diarization moved fully in-process onto the ANE (PT-P5-D1, PT-P5-D3), so the old captive `python/` subprocess (pyannote/diart) is gone.

IPC, per recording session:
- The capture daemon (`pulsartrace-capture`) streams length-prefixed PCM frames (16 kHz mono Float32) over per-session Unix domain sockets — one for system audio, one for mic — that the engine reads via `SocketSource` (`FrameProtocol`).
- A JSON-line control protocol (`ControlProtocol`) carries engine ↔ UI/CLI control messages.

If you find yourself reaching for a second language, stop. The fewer moving parts, the better.

## Test discipline

Build and tests run unsandboxed and bare — see `CLAUDE.md` for the exact invocation. Use the **narrow** `--filter` suites; never `swift test --filter PipelineTests` (known cross-suite flaky — `CLAUDE.md` lists the green narrow filters).

Layer | Speed | When
---|---|---
`swift test --filter UnitTests` | fast | Every non-trivial change
`swift test --filter Refinement` / `Streaming` / `Speaker` / `RecordOrchestrator` / `LiveRunner` / `IPC` | seconds–minutes | Every change to the matching area
`swift test --filter Parakeet` / `WhisperKitRefine` / `FluidVAD` / `DiarizationE2E` | one-time model download, then seconds | ANE backend changes
`PULSARTRACE_DEVICE_TESTS=1 swift test --filter Capture` | ~60s | Capture-daemon changes (needs BlackHole)
Manual smoke (`docs/release-smoke-test.md`) | ~5min by human | Before each release tag

Non-negotiable rules:
- **Tests ship with the code that creates them.** No separate "testing epic." If you can't write the test, the code isn't done.
- **Every test must pass or be explicitly gated** (`.disabled`/`.enabled(if:)` with a one-line reason). Never leave a red suite — even a test you think is "flaky" or "unrelated" is yours the moment you see it.
- **Determinism is mandatory.** Seeded RNG, content-digest-pinned model bundles, fixture audio committed to repo. Without these, snapshot tests flake and you'll be tempted to "fix" the test.
- **Snapshot test failures are not bugs to fix by updating the snapshot.** They indicate a contract change that needs explicit justification. If you're updating a snapshot, ask whether the contract change is intentional, and say so in the commit.

## Things LLMs tend to get wrong on this project

Watch for these specifically:

1. **Writing to live.md after creation in any way other than appending.** Updating "Unknown #2" to a name, fixing a typo, anything. Always append-only.
2. **Reading the speaker library during the live pass and treating it as authoritative.** Live reads are for display only; the post-pass is the source of truth for library state.
3. **Reloading a recognition model per chunk.** The Parakeet (live) and WhisperKit (refine) models must be **resident** — one resident engine per process, kept alive for the session, shared across streams.
4. **Adding telemetry "just for the model download."** Even a `?version=1.0.0` query param on the download URL is telemetry. Don't.
5. **Writing event types with ambiguous timing.** Events MUST be emitted in causal order. `speaker_renamed` BEFORE `final_md_rewritten`, not after.
6. **Treating speaker names as identifiers.** Always use `spk_<ulid>` IDs internally and in events. Names are display strings that can change.
7. **Letting the refine pass hallucinate "thanks for watching" on silence.** The hallucination double-gate (PT-P2-D13) is ported onto WhisperKit's per-segment `noSpeechProb`/`avgLogprob`; VAD-gate the input.
8. **Storing audio at 48kHz stereo float32.** The canonical storage format is 16kHz mono Int16 PCM WAV (PT-R54e). Resampling/downmixing happens at the capture-source boundary, not at storage time.
9. **Editing a frozen Erratum artifact in place.** Closed epics/projects are immutable; a correction is a `-revN` sibling epic, and the product layer changes only at project close-out.
10. **Forgetting the `version` field in events.** Every event has `ts`/`type`/`id`/`version`. The `version` lets us evolve schemas per-type without breaking the whole consumer base.

## When in doubt

In order:

1. **Re-read the relevant epic spec under `.erratum/projects/`** and the product requirements it implements. Its scope and edge cases tell you what you're responsible for.
2. **Check the contract files** (`transcript-format.md`, `events-log.md`) if the change touches a public API surface.
3. **Look at how an existing similar feature is structured.** The conventions are consistent across the codebase.
4. **Ask the human** if a change would violate an invariant, or if you're uncertain which initiative a feature belongs to.

## Communication style

When reporting on PulsarTrace work, lead with what's done, what's tested, and what events the change emits. Skip flourish. Examples:

✅ "Refine pass done. PT-R107, PT-R11, PT-R13 covered. Pipeline tests passing on `two-speakers-overlap` fixture. Events `refinement_started`/`completed` wired in."

❌ "I've finished a comprehensive implementation of the offline transcription functionality with full ANE integration and complete test coverage across multiple test scenarios."
