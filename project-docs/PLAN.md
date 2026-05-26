# PulsarTrace — Implementation Plan (checkpointed)

Scope: **v0.1 (Epics 1–5), Epic 6 (streaming), Epic 7 (real device capture),
Epic 8 (menubar UI), and Epic 9 (CLI surface) are delivered, verified, and
committed.** Epic 9 was implemented before Epic 8 — see `DECISIONS.md` D23.
Epic 10 (distribution) remains for a later run.

Epics 1–6 were built on an audio-deviceless host; Epics 7 and 9 were built on a
real-audio-capable Mac (BlackHole + TCC grants — see `PREWORK.md`).

Source of truth: `PRD.md`. Architectural deviations logged in `DECISIONS.md`.

Dev environment, the audio/capture stack, and the Claude Code sandbox model
(what runs sandboxed vs not, and why) are documented in `PREWORK.md` — read it
before running builds, tests, or capture on a new machine.

Workflow per epic: plan → implement (subagents) → review (subagents) → test green → commit on `main`.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done & committed

---

## Epic 1 — Foundations  ✅ committed b7c1cfa
- [x] SwiftPM package structure: `PulsarTraceEngine` lib, `pulsartrace-engine` exe, `pulsartrace` CLI exe
- [x] Test targets `UnitTests` / `PipelineTests` / `CaptureTests` (Swift Testing) + snapshot testing wired
- [x] `swift-log` dual backend (os.Logger + rotating file logger), 7-day retention, content-leak test
- [x] Events log: JSONL writer, ULID, common envelope, `app_started`/`app_stopped`, 30-day rotation
- [x] `AudioFrameSource` protocol + `FixturePlaybackSource`, `PipeSource`, `SocketSource`
- [x] IPC scaffolding: `control.sock` (JSON-line) + `capture.sock` (binary frame protocol def)
- [x] Python package skeleton (`python/pulsartrace-ai`), venv build script, pytest harness
- [x] Audio fixtures committed; `ffmpeg -re | pulsartrace-engine --stdin` frame-count smoke
- [x] DONE: Unit+Pipeline green <30s; pytest green; pipe smoke works; event pair emitted

## Epic 2 — Offline Transcription  ✅ committed e769e12
- [x] whisper.cpp v1.8.4 vendored + built with Metal (scripts/build-whisper.sh, D7);
      `CWhisper` systemLibrary target; resident model via `WhisperTranscriber` (R9)
- [x] `ModelStore`: HF download, HTTP Range resume (R54c) + SHA-256 verify (R54d);
      `model_downloaded` event; multilingual `base` + `large-v3` pinned in `ModelCatalog`
- [x] `WAVWriter`: canonical Int16 16kHz mono WAV storage (R54e)
- [x] Offline transcribe from any `AudioFrameSource` — single `whisper_full` over the
      whole stream, so no chunk-boundary artifacts (R11); `OfflineTranscriptionPipeline`
- [x] `TranscriptDocument` R13 format; `BlankTokenFilter` + no-speech threshold
- [x] DONE: `pulsartrace-engine --source fixture --transcribe` → snapshot-matched markdown;
      Unit+Pipeline green; determinism confirmed (6× stable). D8: Metal single-context lock.

## Epic 3 — Offline Diarization  ✅ committed 72efa77
- [x] pyannote community-1 via embedded Python (`pulsartrace_ai/diarize.py`);
      speaker spans + per-speaker 256-d embeddings + pyannote version string;
      seeded RNGs → deterministic; overlap preserved (D9/D10)
- [x] Swift `Diarizer`: one-shot subprocess, timeout + stderr→log `[python]`
      (R60); `DiarizationDecoder` JSON contract with `schema` field (D11)
- [x] `DiarizationMerge`: transcript ⨉ spans by dominant overlap → real
      `Speaker_N` labels; mic never diarized — only `diarizeSystemStream` (R17)
- [x] requirements.lock pinned (torch 2.12 / pyannote.audio 4.0.4); build-venv.sh
- [x] DONE: pytest green (real pyannote, 11 tests); Unit+Pipeline green <30s;
      committed diarization JSON fixtures; merged `**[HH:MM:SS] Speaker_0:**`
      markdown snapshot stable across runs. R15a, R17, R29 covered.

## Epic 4 — Refinement Pipeline (`pulsartrace refine`)  ✅ committed f56c956
- [x] `RefinementPipeline`: WAV/folder → whisper transcribe → pyannote diarize →
      timestamp merge → reconciled `Speaker_N`/`You` markdown (R20, R21)
- [x] `RecordingFolder` input dispatch: bare-WAV → sibling output folder (D13);
      recording folder with `audio-system.wav` (+ optional `audio-mic.wav`, R17)
- [x] `AtomicFile` write-then-rename (D14); `final.md` marker (R24/R38);
      `.live.md.bak`; re-refine → `final.md.bak` (R27)
- [x] `metadata.json` sidecar — recording id, durations, speakers, whisper +
      pyannote model identity, schema version (R39)
- [x] Events: refinement_started/completed/failed, final_md_written/rewritten,
      live_md_replaced_by_final — emitted in causal order
- [x] `pulsartrace refine PATH [--model base|large-v3]` (R48); stderr progress (R26)
- [x] Edge cases: no-speech → valid empty-transcript final.md; failure →
      refinement_failed + non-zero exit
- [x] DONE: `pulsartrace refine meeting.wav` → working `final.md` (v0.1 ship-able);
      Unit 90/90 green; Pipeline green incl. real whisper+pyannote e2e + re-refine

## Epic 5 — Speaker Library  ✅ committed 515d480  — v0.1 milestone complete
- [x] SQLite store (built-in `SQLite3`, WAL, D17); centroid running-mean (R30);
      soft-delete 30-day undo (R32b); last-good backup + auto-restore on corruption
- [x] Reconcile post-pass clusters vs library (R22/R23); `spk_<ulid>` stable IDs
      (R83); cross-model-revision matches refused (Open Q #3); real
      `speakers_new`/`speakers_matched` counts in `refinement_completed`
- [x] `pulsartrace speakers list/rename/merge/delete` (R49); split lib op exists
      (CLI surface deferred to Epic 8). Rename/merge do not retroactively rewrite
      past `final.md` — Epic 8 scope (D16)
- [x] Events: speaker_* family + library_backup_created/library_corruption_detected
- [x] DONE: 2nd recording with returning speaker auto-applies name — verified via
      pipeline test + real-pyannote CLI smoke (`Unknown #1` carried A→B)
- New DECISIONS: D16 (Epic 5 rename/merge ≠ retroactive rewrite), D17 (built-in SQLite3)

## Epic 6 — Streaming Transcription & Diarization  ✅ committed 345d24d
- [x] `StreamingTranscriber`: anchored-window whisper + LocalAgreement-2
      committer — emits only *committed* utterances; resident whisper context
      reused; VAD-gate + `BlankTokenFilter`; backpressure handling (D20, R10)
- [x] `LiveDiarizer`: windowed-pyannote (NOT diart — D19/Open Q #1: diart would
      downgrade pyannote 4.0.4→3.4.0 and break Epic 3). Long-lived
      `pulsartrace_ai.live_diarize` subprocess, newline-JSON window protocol,
      embedding-stitched provisional `Them`/`Them #N` keys (R15, R16)
- [x] `LiveMarkdownWriter`: strictly append-only `live.md` — created at session
      start with marker + header (R35a/R37), monotonic byte growth, atomic
      per-line append (R12/R36); emits `live_md_started`
- [x] `MicEchoDedup`: text-similarity ±5s mic-echo drop (R19)
- [x] Read-only speaker-library lookup during live → known names, still
      `(provisional)` (R18, R32); library never written by the live pass
- [x] `pulsartrace-engine --live [--stdin|--source fixture] [--out] [--model]
      [--no-live-diarization]`; single piped stream → system stream; writes
      `audio-system.wav` so a later `refine` works
- [x] Tests: Unit (LocalAgreement-2, mic-echo, line format, append-only writer,
      grouping, `live_md_started` snapshot); Pipeline (e2e live run, snapshot,
      realtime-paced monotonic-growth + bounded-lag, mic-echo)
- [x] DONE: `ffmpeg -re fixture.wav | pulsartrace-engine --stdin --live` → growing
      `live.md` (verified monotonic), provisional labels; subsequent
      `pulsartrace refine` → `.live.md.bak` + `final.md` + `live_md_replaced_by_final`
- New DECISIONS: D19 (windowed-pyannote over diart), D20 (anchored-window
  whisper + LocalAgreement-2)

## Epic 7 — Real Device Capture  ✅ committed a673a7f
- [x] `PulsarTraceCapture` library + thin `pulsartrace-capture` executable
      (D22); `CaptureTests` imports the library for device-gated tests
- [x] `DeviceCaptureSource` orchestrator: two `CaptureSocketServer`s (system +
      mic), `MicCaptureEngine` (AVFoundation, R1, R5), `SystemAudioCaptureEngine`
      (ScreenCaptureKit, R2 — no BlackHole in production), `AudioConverter`
      resample/downmix to 16 kHz mono Float32 at the source boundary (R54e)
- [x] Two Unix sockets, each a single-stream `FrameProtocol`; engine consumes
      via `SocketSource` — `pulsartrace-engine --live --system-socket S
      --mic-socket M` (R3); listen-before-connect handshake via a `ready` line
- [x] `FrameProtocol` in-band pause/resume control frames (D21); `SleepWakeMonitor`
      (IORegisterForSystemPower → dispatch queue) drives pause/resume across
      sleep (R7) and device change (R8); `LiveRunner` annotates `live.md` with
      `_(recording paused)_` / `_(recording resumed after …)_`
- [x] `PermissionChecker` — Microphone + Screen Recording TCC; the capture
      daemon is the only TCC-gated process (R4)
- [x] Events: `recording_started/paused/resumed/stopped`, `permission_changed`
      — emitted by `pulsartrace-capture`; schema in `docs/events-schema.md`
- [x] Tests: Unit (`FrameProtocol` control frames, `AppPaths` sockets, event
      snapshots, `live.md` gap annotation); CaptureTests non-device
      (`AudioConverter`, `CaptureSocketServer` round-trip) + device-gated
      (`SystemAudioCaptureEngine`/`MicCaptureEngine` real capture); Pipeline
      IPC two-socket + pause/resume integration
- [x] DONE: device tests pass real SCK + AVFoundation capture
      (`PULSARTRACE_DEVICE_TESTS=1`); two-socket live pass produces `live.md`;
      pause/resume control frames annotate the gap
- New DECISIONS: D21 (in-band pause/resume control frames), D22 (`PulsarTraceCapture`
  module layout)

## Epic 9 — CLI Surface  ✅ committed 73a4eab

Implemented **before** Epic 8 — see `DECISIONS.md` D23. `refine`/`speakers`
already shipped (Epics 4–5); Epic 9 completes the `pulsartrace` surface.

- [x] `pulsartrace record` (R47) — `RecordOrchestrator` (`PulsarTraceEngine`)
      spawns `pulsartrace-capture` + `pulsartrace-engine --live`, runs for
      `--duration` min (or until Ctrl-C), then refines → `final.md`. `RecordPlan`
      builds the capture/engine argv. Flags: `--output`, `--duration`, `--mic`,
      `--no-system-audio`, `--model`, plus additive `--list-mics`. macOS-14 /
      Intel host guards. D23, D24.
- [x] `pulsartrace doctor` (R50) — `EnvironmentDoctor` pure checks: macOS
      version, CPU arch, whisper model cache, Python runtime, speaker library,
      TCC permissions, writable directories → actionable report, exit 1 on any
      hard failure.
- [x] `pulsartrace doctor --capture-test` (R68) — `CaptureSelfTest` plays a
      440 Hz tone, captures it back through the real mic path, verifies the
      dominant frequency via `ToneDetector` (Goertzel).
- [x] `pulsartrace events tail` (R86) — `EventLogTail` streams today's events
      JSONL; `--type` filter (repeatable, validated against `EventRegistry`),
      `--no-follow`, SIGINT-clean follow loop.
- [x] `pulsartrace install-cli` (R51) — `CLIInstaller` symlinks into
      `/usr/local/bin` (explicit-invocation consent); prints the `sudo` command
      when the dir is not writable; `--uninstall`.
- [x] Tests: Unit (`EventLogTail`, `EnvironmentDoctor`, `CLIInstaller`,
      `RecordPlan`, `ToneDetector` — 35 tests); Pipeline (`RecordOrchestrator`
      against stand-in `/bin/sh` daemons — ready handshake, timeout, teardown);
      Capture device-gated (`CaptureSelfTest`).
- [x] DONE: Unit 210/210 green; `RecordOrchestrator` pipeline tests green;
      CLI dispatch wired for `record`/`doctor`/`events`/`install-cli`.
      Real-audio `record` end-to-end + `doctor --capture-test` frequency match
      are release-smoke items (`docs/release-smoke-test.md`).
- New DECISIONS: D23 (Epic 9 before Epic 8; `RecordOrchestrator` placement),
  D24 (`record --output`/`--model` semantics).

## Post-Epic-9 refine fixes  ✅ committed 7df7624, e91e369, 7d2a4aa

Bug fixes to the Epic 4 `refine` pass, surfaced from a real two-party
recording (not new epic scope):

- [x] Garbled `final.md`: a whole-recording `whisper_full` call degenerated
      into a repetition loop on long digital silence. Fix: non-zero whisper
      temperature + fallback ladder, plus Silero VAD. **D25.**
- [x] Mis-ordered `final.md`: D25's built-in VAD concatenated speech across
      pauses, gluing multi-turn monologues into one segment that sorted ahead
      of the other speaker. Fix: detect VAD speech regions separately,
      coalesce <800 ms gaps, decode each region as its own call. **D26.**
- [x] End-to-end D26 regression test (verified TDD-style against the pre-fix
      commit).

---

## Epic 8 — Menubar UI  ✅ committed 4691621

Implemented after Epic 9 (D23). A SwiftPM library + thin SwiftUI executable —
no `.xcodeproj` / `.app` bundle (D27); that is Epic 10.

- [x] `FinalMarkdownRewriter` (`PulsarTraceEngine`) — retroactive `final.md`
      rewrite after a speaker rename/merge/split/unmerge/unsplit: resolves the
      affected recordings via the appearances table, atomic write + `.bak`,
      skips byte-identical recordings, updates `metadata.json` labels, never
      touches `live.md` (R36, Hard Invariant #4). Pays the D16 debt.
- [x] `SpeakerLibrary` `suppressEvent:` overloads (additive) on
      rename/merge/split so the caller emits the `speaker_*` event after the
      rewrite with a populated `applied_to_recordings` — causal order (#8).
- [x] `OfflineRefiner` (`PulsarTraceEngine`) — in-process refine shared by the
      `pulsartrace refine` CLI and the menubar; the menubar never shells out to
      the `pulsartrace` CLI (D23 / D28).
- [x] `PulsarTraceMenuBar` library — `@Observable` ViewModels/state: status
      machine (R40), `RecordingViewModel` start/stop + crash-watch (R41),
      `MenuBarSettings` persisted to `UserDefaults` (R42),
      `SpeakerEditorViewModel` list/rename/merge/split/delete + undo, name
      validation (R31/R43), `RecordingsScanner` `metadata.json` scan + re-refine
      (R44), `LiveTranscriptWatcher` read-only poll-tail of `live.md` (R45).
      Onboarding tour stubbed (R46 — P2, deferred).
- [x] `pulsartrace-mac` executable — `MenuBarExtra` SwiftUI shell, `.accessory`
      activation policy, passive `NSEvent` global hotkey (D27). Views are pure
      bindings; empty states for the speaker editor + recordings list.
- [x] Tests: `MenuBarTests` (25 — settings round-trip, scanner, status machine,
      speaker-editor retroactive rewrite + populated events, live watcher);
      `FinalMarkdownRewriterTests` (9, Pipeline). Unit 217 + MenuBar 25 green;
      `swift build` clean for all targets. Pipeline green bar the pre-existing
      whisper-snapshot flakes (`returningSpeakerAutoLabelled`, streaming
      `live.md` body) — concurrent-whisper non-determinism, D8/D14; both pass
      in isolation and Epic 8 touches no whisper/streaming code.
- [x] DONE: the full core flow is reachable without a terminal; a retroactive
      rename rewrites every past `final.md`. `.app` packaging + the manual UI
      smoke pass are Epic 10.
- New DECISIONS: D27 (menubar module layout; passive hotkey), D28
  (`OfflineRefiner` in-process refine), D29 (menubar splits the live and
  refine transcription models).
- KNOWN FOLLOW-UP (deferred to Epic 10): starting a recording without TCC
  grants races the OS permission prompt — the app can surface a
  "permissions not granted" error before the user finishes responding. The
  Epic 10 first-run permissions wizard will request and confirm grants up
  front, before the first start.

---

## Post-Epic-8 menubar fixes  ✅ committed 5c29483 … 4b3d024

Fixes from dogfooding the running `pulsartrace-mac` build — not new epic
scope:

- [x] Launch crash: `NSApp` is `nil` in `App.init()` (SwiftUI has not built
      the application object yet) — use `NSApplication.shared`. Commit 5c29483.
- [x] `scripts/make-dev-app.sh`: minimal unsigned `.app` wrapper so the
      `MenuBarExtra` app is launchable before Epic 10 (a bare `swift run`
      shows no menu-bar item — needs a bundle with `LSUIElement`). Commit
      819095d.
- [x] Post-recording refine skipped ("folder not found"): `stopRecording`
      re-discovered the folder by scanning for `metadata.json`, which the
      refine pass itself writes — a catch-22. Now carries the recording
      folder through. Commit 737f747.
- [x] Round 2 (commit 1ba879c): the live-transcript popover never updated
      (`LiveTranscriptWatcher` was created but never `start()`-ed at a file);
      menu navigation replaced `.sheet`-on-`MenuBarExtra` with inline pages,
      fixing a confused Done/re-click state and an off-screen sub-window;
      the recordings list now surfaces unrefined folders (`live.md`, no
      `metadata.json`); the transcription model split into live + refine.
- [x] Output folder persisted as a plain path, not a security-scoped
      bookmark — v1 is unsandboxed (PRD §17) and the bookmark resolved stale
      across unsigned dev rebuilds, losing the selection. Commit ae1ea8f.
- [x] Whisper silence-hallucination filter: a confidently-decoded stock
      phrase (`"Thank you."` …) leaked into `final.md` from a near-silent
      stream. `HallucinationFilter` drops such a segment only when an
      objective per-segment signal (`no_speech_prob` / avg logprob) also
      says the audio was silence — a real utterance is never dropped on
      phrase text alone. Offline path only. Commit 4b3d024.
- New DECISIONS: D29 (live/refine model split), D30 (output folder = plain
  path), D31 (offline silence-hallucination filter).
- KNOWN (deferred to Epic 10): TCC grants do not survive unsigned dev
  rebuilds — each build changes the binary's cdhash, so macOS stops
  applying the grant while the System Settings toggle still shows it ON.
  Stable code-signing (Epic 10) is the fix.

---

## Live-recording resilience fixes  ✅ committed b386c37

Fixes from a dogfooding incident: a real ~18-minute recording where the
ScreenCaptureKit system-audio stream silently stalled, then ~2 min later the
mic stream, leaving the engine wedged (alive, not crashed — no `.ips` crash
report) with the menubar still showing "recording". On Stop the refine failed:
the recording folder held only `live.md`, no `audio-system.wav`. Root cause:
the live pass buffered the whole recording in RAM and wrote the WAV only at
the end of a clean run-loop exit, so the wedge-then-force-kill lost 100% of the
audio. Not new epic scope.

- [x] Crash-safe incremental WAV (`StreamingWAVWriter`): `LiveRunner` streams
      `audio-system.wav`/`audio-mic.wav` to disk frame-by-frame, re-patching
      the RIFF header so the on-disk file is always a valid, refine-able WAV
      (≤1s lost on a hard kill). Replaces the in-RAM `diarBuffer`/`micBuffer`
      end-of-run dump; `micBuffer` removed, `diarBuffer` kept only as the live
      diarizer's window source and now bounded.
- [x] Capture-daemon stall detection + auto-restart: a per-engine
      `FrameWatchdog` fires after no audio for 6s (system) / 4s (mic);
      `DeviceCaptureSource.handleStall(stream:)` rebuilds the stalled capture
      engine — mirroring the existing sleep/wake recovery — with capped
      exponential-backoff retry re-scheduled off the serial restart queue.
      Emits `recording_paused`/`recording_resumed` with `reason:
      "stall_recovery"`; the socket stays open, so the engine just sees a
      pause/resume pair.
- [x] Engine run-loop resilience: a periodic `.tick` drives a per-stream
      silence watchdog (20s) that annotates a gap in `live.md` without ever
      wedging or prematurely ending the loop — it exits only on a real socket
      EOF. The live diarizer is moved off the run-loop critical path (a
      detached task bounded to one window in flight by a `DiarGate` actor), so
      a stuck diarizer subprocess can no longer stall transcription / WAV /
      `live.md`.
- [x] Tests: Unit (`StreamingWAVWriter` crash-safety, `DiarGate`); Capture
      (`FrameWatchdog`, stall thresholds, retry backoff, stale-callback guard
      — all non-device); Pipeline (`LiveRunnerResilience` — stalled stream
      does not wedge, append-only gap, hung-diarizer isolation, bounded
      `diarBuffer`). Unit 236, Capture 30 green; Pipeline green bar the two
      pre-existing concurrent-whisper snapshot flakes (`returningSpeakerAuto-
      Labelled`, streaming `live.md` body — D8; both pass in isolation).
- New DECISIONS: D32 (crash-safe incremental WAV), D33 (capture-stall
  detection + auto-restart reusing the pause/resume mechanism).
- KNOWN FOLLOW-UP (tracked, deferred): (a) root-cause why the ScreenCaptureKit
  system-audio stream stalls in the first place; (b) live-diarization windows
  fail with `nan` embeddings on near-silent / too-short windows (`Mean of
  empty slice`) — they should yield empty results, not a hard per-window
  error.

---

## Refinement job queue & resumable pipeline  ✅ committed 1276a7d … 295edd2

A queue-based refactor of refinement state so back-to-back recordings stop
blocking on a still-running refine. Driven by a real user issue: the finished
recording auto-triggered refinement, and that blocked starting the next
meeting. Now: a recording stops, the auto-refine is enqueued, and the menubar
state machine goes idle immediately — the next recording can start. If a
recording does start while a refine is in flight, the queue pauses the refiner
(closing a pause gate + killing the inflight pyannote subprocess) so capture
gets the resources it needs; the refine resumes from its on-disk checkpoint
when the recording stops. Manual "Refine" from the recordings list and
auto-post-recording refine both feed the same FIFO single-worker queue.

- [x] `RefinementJob` + `RefinementJobState` value types (jobId/recordingId/
      trigger/state machine across queued/running/paused/completed/failed/
      cancelled).
- [x] `RefinementJobStore`: atomic-file JSONL persistence, `listAll`/`upsert`/
      `pruneTerminal` (older than N days).
- [x] `RefinementProgress` checkpoint schema written to
      `<folder>/refine-progress.json`: VAD regions, completed-region indices
      per stream, partial segments, language, last stage.
- [x] `PauseGate` actor (open/close/waitOpen) — async checkpoint primitive
      shared between the queue and the refiner.
- [x] `WhisperTranscriber.transcribeRegion(_:region:options:)` exposed so the
      refiner can decode one VAD region at a time and checkpoint between them.
- [x] `Diarizer.cancel()` — SIGTERM + 500ms SIGKILL escalation of the inflight
      pyannote subprocess, surfacing as `DiarizeError.cancelled`.
- [x] `ResumableRefiner` actor: 8-stage refine loop with per-region whisper
      checkpointing, per-region pause-gate wait, and a diarize cancel-retry
      loop (cancelled diarize is not a failure — refiner waits for the gate to
      reopen and re-runs from scratch, per D-Q7).
- [x] `RefinementJobQueue` actor: single-worker FIFO; `enqueueManualRefine` /
      `enqueueAutoRefine` / `enqueueCrashRecovery`; `pauseForRecording` /
      `resumeAfterRecording`; `cancel(recordingId:)` for queued jobs;
      `reportStage(_:)` hook the refiner uses to update running-job state for
      the UI; `setInflightCancellable(_:)` so pause additionally terminates
      the inflight diarizer.
- [x] `RefinementJobQueue.makeStandard` production factory wires real
      `WhisperTranscriber` + `Diarizer` + `EventWriter` + shared `PauseGate`
      with the standard `paths` store.
- [x] `RecordingStatus.refining` removed; `RecordingViewModel.stopRecording`
      and `recoverFromCrash` now enqueue via an injected `enqueueAutoRefine`
      closure and return to `.idle` immediately.
- [x] `AppEnvironment` wires the queue: `RefinementJobQueue.makeStandard` in
      a deferred `bootstrap()` task chained after `events.bootstrap()`;
      `toggleRecording` calls `pauseForRecording` before start, resumes after
      stop or on failed start. `RefinementJobQueueViewModel` (`@MainActor
      @Observable` façade) injected into the unified window environment.
- [x] Refinements sidebar pane (`RefinementsListView`): Running / Queued /
      Recent sections with per-job progress (% + stage + region) and a Cancel
      button on queued rows; empty state. 250 ms snapshot poll for v1.
- [x] Recordings list: Refine button enqueues via the queue (no longer
      in-process). Per-row `RefineBadge` shows Refining/Queued/Refined/Failed.
      `RecordingsScanner`'s `reRefiner` / `reRefine` / `ReRefineError` /
      `makeDefaultReRefiner` deleted; only folder reading remains.
- [x] Menubar dropdown status reflects the queue: "Recording since … ·
      Refining 42% (transcribingSystem)" when both, "<N> queued" when idle
      with a backlog.
- [x] `OfflineRefiner` doc-comment updated — it is now the CLI-only one-shot
      path; the menubar uses the queue.
- [x] Tests green: `--filter UnitTests` 253/253; `--filter MenuBarTests`
      34/34; `--filter RefinementJobQueueTests` 6/6; `--filter
      ResumableRefiner` 4/4. New DECISIONS: D34, D35, D36.
- [x] Branch close-out: typed error classification (C3), settings closure removed (C5), pruneTerminal wired into queue start with 30-day retention, retain cycle in makeStandard broken via weak capture, PauseReason gains a displayName, placeholder queue uses a temp directory. The 250 ms polling cadence is promoted to D35.
- [x] **Follow-up landed in a separate change** (see `docs/specs/2026-05-20-refine-perf-and-capture-resilience-plan.md`): D36 reopened — `WhisperTranscriber` is reused across regions within a job via `SharedTranscriberBox`; `RefinementProgress` gains an optional `lastError` field that `ResumableRefiner.run` populates on failure; `DeviceCaptureSource.makeSystemEngine` now wires `onStreamError` into the stall-restart path (gap that surfaced on session 2026-05-20-113001); `EventWriter.append` acquires `flock(LOCK_EX)` (D37) so cross-process appends can no longer interleave.

---

## Cross-cutting (every epic)
- Tests ship with code. Determinism: seeded RNG, whisper temp 0, pinned hashes.
- `docs/file-format.md` and `docs/events-schema.md` kept current.
- No telemetry; no in-app LLM; all audio through `AudioFrameSource`; live.md append-only.
