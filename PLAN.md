# PulsarTrace — Implementation Plan (checkpointed)

Scope for this run: **v0.1 (Epics 1–5) delivered solid + verified, then Epic 6 (streaming).**
Epics 7–10 are explicitly out of scope (no audio devices / UI session / signing on this host).

Source of truth: `PRD.md`. Architectural deviations logged in `DECISIONS.md`.

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

## Epic 2 — Offline Transcription  ✅ done & verified (not committed)
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

## Epic 6 — Streaming Transcription & Diarization  ✅ done & verified (not committed)
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

---

## Cross-cutting (every epic)
- Tests ship with code. Determinism: seeded RNG, whisper temp 0, pinned hashes.
- `docs/file-format.md` and `docs/events-schema.md` kept current.
- No telemetry; no in-app LLM; all audio through `AudioFrameSource`; live.md append-only.
