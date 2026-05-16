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

## Epic 3 — Offline Diarization  ✅ done & verified (not committed)
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

## Epic 4 — Refinement Pipeline (`pulsartrace refine`)
- [ ] Full offline command: WAV → text → spans → reconciled markdown
- [ ] Atomic `final.md` write, `.live.md.bak`, `metadata.json` sidecar, re-refine
- [ ] Events: refinement_started/completed/failed, final_md_written/rewritten, live_md_replaced_by_final
- [ ] DONE: `pulsartrace refine meeting.wav` → working `final.md` (v0.1 ship-able)

## Epic 5 — Speaker Library
- [ ] SQLite store (WAL), centroid running-mean, soft-delete 30-day undo
- [ ] Reconcile post-pass clusters vs library; `spk_<ulid>` stable IDs
- [ ] `pulsartrace speakers list/rename/merge/delete`
- [ ] Events: speaker_* family, library_backup_created, library_corruption_detected
- [ ] DONE: 2nd recording with returning speaker auto-applies name

## Epic 6 — Streaming Transcription & Diarization
- [ ] Whisper streaming + diart live speaker IDs from any `AudioFrameSource`
- [ ] Atomic append `live.md` (R12/R35a/R36/R37), provisional labels, mic-echo dedup
- [ ] Library lookup read-only during live (R32); event `live_md_started`
- [ ] DONE: `ffmpeg -re fixture.wav | pulsartrace-engine --stdin --live` → growing `live.md`

---

## Cross-cutting (every epic)
- Tests ship with code. Determinism: seeded RNG, whisper temp 0, pinned hashes.
- `docs/file-format.md` and `docs/events-schema.md` kept current.
- No telemetry; no in-app LLM; all audio through `AudioFrameSource`; live.md append-only.
