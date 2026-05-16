# PulsarTrace — Implementation Plan (checkpointed)

Scope for this run: **v0.1 (Epics 1–5) delivered solid + verified, then Epic 6 (streaming).**
Epics 7–10 are explicitly out of scope (no audio devices / UI session / signing on this host).

Source of truth: `PRD.md`. Architectural deviations logged in `DECISIONS.md`.

Workflow per epic: plan → implement (subagents) → review (subagents) → test green → commit on `main`.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done & committed

---

## Epic 1 — Foundations
- [~] SwiftPM package structure: `PulsarTraceEngine` lib, `pulsartrace-engine` exe, `pulsartrace` CLI exe
- [~] Test targets `UnitTests` / `PipelineTests` / `CaptureTests` (Swift Testing) + snapshot testing wired
- [~] `swift-log` dual backend (os.Logger + rotating file logger), 7-day retention, content-leak test
- [~] Events log: JSONL writer, ULID, common envelope, `app_started`/`app_stopped`, 30-day rotation
- [~] `AudioFrameSource` protocol + `FixturePlaybackSource`, `PipeSource`, `SocketSource`
- [~] IPC scaffolding: `control.sock` (JSON-line) + `capture.sock` (binary frame protocol def)
- [~] Python package skeleton (`python/pulsartrace-ai`), venv build script, pytest harness
- [~] Audio fixtures committed; `ffmpeg -re | pulsartrace-engine --stdin` frame-count smoke
- [~] DONE: Unit+Pipeline green <30s; pytest green; pipe smoke works; event pair emitted
      (implemented + verified; `[x]` once the coordinator commits on `main`)

## Epic 2 — Offline Transcription
- [ ] whisper.cpp built with Metal; resident model; multilingual `base` + `large-v3`
- [ ] Model download (HTTP Range resume R54c) + SHA-256 verify (R54d)
- [ ] Canonical Int16 16kHz mono WAV storage (R54e)
- [ ] Transcribe any `AudioFrameSource`; overlap windowing / LocalAgreement-2 (R11)
- [ ] Output format R13; VAD-gate + `[BLANK_AUDIO]` filter
- [ ] DONE: `pulsartrace-engine --source fixture --transcribe` → snapshot-matched markdown

## Epic 3 — Offline Diarization
- [ ] pyannote community-1 via embedded Python; speaker spans + embeddings
- [ ] Merge transcript + speaker spans by timestamp; mic never diarized (R17)
- [ ] DONE: fixture WAV → `**[HH:MM:SS] Speaker_0:**` lines stable across runs

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
