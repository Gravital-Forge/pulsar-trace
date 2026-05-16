# PulsarTrace

**Local-only meeting transcription with speaker labels. Plug your AI agent into the file. Open source.**

PulsarTrace turns a meeting recording into a clean, speaker-labeled Markdown transcript — and it never sends your audio anywhere. Transcription (whisper.cpp) and speaker diarization (pyannote) run entirely on your Mac. The output is plain Markdown and JSONL on disk, designed to be read by your AI agent of choice (Claude Code, Cursor, opencode, …) during or after the call.

Part of the Gravital Forge product family (sibling to OrbitNote).

---

## Status

> **v0.1 — offline pipeline + live streaming.** Buildable and usable today as a command-line tool.

| Capability | State |
|---|---|
| Offline refinement (`pulsartrace refine`) — audio → speaker-labeled `final.md` | ✅ Working |
| Streaming transcription + live diarization → append-only `live.md` | ✅ Working |
| Persistent speaker library — recognizes recurring voices across recordings | ✅ Working |
| Events log (`events/*.jsonl`) — machine-readable activity stream | ✅ Working |
| Real microphone / system-audio capture | ⏳ Planned (Epic 7) |
| Menubar app, signed/notarized DMG, first-run wizard | ⏳ Planned (Epics 8–10) |

Today PulsarTrace is a **file-in / file-out CLI**: you feed it a WAV (or pipe PCM into it), it produces transcripts. Live device capture and the menubar UI are the next milestone — see [Roadmap](#roadmap). This split is deliberate: the entire AI pipeline is built and tested against an audio-source abstraction, so it works fully without touching audio hardware.

---

## Why PulsarTrace

Every dominant meeting-transcription tool (Otter, Fireflies, Granola, Fathom, Zoom AI) ships your audio to the cloud. For anyone under NDA, working on confidential systems, or who simply doesn't want their meetings on someone else's servers, that disqualifies the whole category.

- **Strictly local.** Your audio never leaves the machine. No telemetry, no analytics, no account, no auto-update pings. The only network calls are first-launch model downloads from Hugging Face.
- **Speaker labels that persist.** Diarization separates who said what, and a speaker library learns recurring voices — so by someone's third meeting they're auto-labeled by name.
- **Two-pass design.** A fast *live* pass writes `live.md` while the meeting happens; an offline *refinement* pass re-runs at full quality afterward and produces `final.md`, the source of truth.
- **Files as the API.** No in-app chatbot. PulsarTrace writes clean Markdown and JSONL; you point your own agent at it. The integration is the product.

---

## Requirements

- **macOS 14 (Sonoma) or later**, Apple Silicon strongly recommended (Metal acceleration). Intel works but is slow.
- **Xcode 16+ / Swift 6** toolchain (`swift --version` should report 6.x).
- **Homebrew** with `cmake`, `ffmpeg`, and `python@3.12`:
  ```bash
  brew install cmake ffmpeg python@3.12
  ```
- **A free Hugging Face account + access token.** The diarization model (`pyannote/speaker-diarization-community-1`) is gated:
  1. Visit https://huggingface.co/pyannote/speaker-diarization-community-1 and accept the terms.
  2. Create a token at https://huggingface.co/settings/tokens.
- ~4 GB free disk for models (whisper `base` ~150 MB, `large-v3` ~3 GB; pyannote ~1 GB).

---

## Build & setup

```bash
git clone <repo-url> gravital-pulsar-trace
cd gravital-pulsar-trace

# 1. Build whisper.cpp with Metal (vendored, commit-pinned — see project-docs/DECISIONS.md D7)
./scripts/build-whisper.sh

# 2. Build the embedded Python diarization environment (pyannote, torch)
./python/build-venv.sh

# 3. Provide your Hugging Face token
echo 'HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx' > .env

# 4. Build the Swift binaries
swift build            # add -c release for production speed
```

This produces two binaries under `.build/debug/` (or `.build/release/`):

- **`pulsartrace`** — the user-facing CLI (`refine`, `speakers`, …)
- **`pulsartrace-engine`** — the streaming engine (consumes any audio source)

Whisper models download automatically on first use into `~/Library/Caches/PulsarTrace/models/`.

---

## Quick start

A 60-second tour. From the repo root:

### 1. Refine a recording → `final.md`

```bash
# Convert any audio to the canonical format first if it isn't already a WAV:
ffmpeg -i meeting.mp3 -ar 16000 -ac 1 -c:a pcm_s16le meeting.wav

.build/debug/pulsartrace refine meeting.wav --model base
```

This transcribes, diarizes, reconciles speakers against the library, and writes a recording folder next to the input:

```
meeting/
  final.md         ← speaker-labeled transcript (the source of truth)
  metadata.json    ← speakers, durations, model identity
```

Use `--model large-v3` for production-quality transcription (slower, larger download).

### 2. Watch a live transcript being written

Live mode consumes audio at real-time pace and grows `live.md` line by line. It needs two terminals.

**Terminal A — tail the live file** (an AI agent would do the same):
```bash
tail -F run/live.md
```

**Terminal B — stream audio into the engine:**
```bash
ffmpeg -re -i meeting.wav -f f32le -ac 1 -ar 16000 - 2>/dev/null \
  | .build/debug/pulsartrace-engine --live --stdin --out run
```

`ffmpeg -re` paces the file in real time, simulating a live meeting. You'll see provisional speaker labels (`Them`, `Them #2`, or known names) appear as words are committed. `live.md` is **strictly append-only** — a `tail -f` reader only ever sees it grow.

Afterward, refine that recording to upgrade it: `pulsartrace refine run` replaces `live.md` with the offline-quality `final.md`.

### 3. Manage the speaker library

```bash
.build/debug/pulsartrace speakers list
```

New voices start as `Unknown #1`, `Unknown #2`, … Give them real names — the stable `spk_…` ID never changes:

```bash
.build/debug/pulsartrace speakers rename spk_01ABC... "Sarah"
.build/debug/pulsartrace speakers merge  spk_01ABC... spk_01XYZ...   # same person, split by mistake
.build/debug/pulsartrace speakers delete spk_01ABC...                 # soft-delete, 30-day undo
```

Renames take effect on the next `refine` of a recording. Once a voice is named, every future recording auto-labels it.

---

## Output formats

PulsarTrace's public API is three plain-text surfaces on disk. They are documented formally in [`docs/file-format.md`](docs/file-format.md) and [`docs/events-schema.md`](docs/events-schema.md), and versioned with SemVer.

### `final.md` — the refined transcript (source of truth)

```markdown
<!-- pulsartrace:final -->
## Transcript — 2026-05-16 14:30

**[00:00:05] Sarah:** So the main issue is the authentication flow breaks on mobile.

**[00:00:12] Unknown #2:** Right, the redirect URI isn't being handled by the webview.
```

### `live.md` — the live transcript (provisional, append-only)

```markdown
<!-- pulsartrace:live -->
## Transcript — 2026-05-16 14:30

**[00:00:05] You:** So the main issue is the auth flow.

**[00:00:12] Them (provisional):** Right, the redirect URI isn't handled.
```

The `<!-- pulsartrace:live -->` / `<!-- pulsartrace:final -->` marker lets a consumer tell a provisional transcript from a finalized one. `(provisional)` annotations and provisional labels are resolved in the refinement pass.

### `events/*.jsonl` — the activity stream

A daily-rotated, append-only JSONL log at `~/Library/Application Support/PulsarTrace/events/`. One self-describing event per line — recording lifecycle, refinement, speaker-library mutations. An agent tails this to know "what just happened."

```jsonl
{"ts":"2026-05-16T14:42:11Z","type":"refinement_completed","id":"evt_01HW...","version":1,"recording_id":"rec_4f2a","speakers_identified":2,"speakers_new":1,"speakers_matched":1}
{"ts":"2026-05-16T14:42:12Z","type":"speaker_created","id":"evt_01HW...","version":1,"speaker_id":"spk_a1b2","initial_name":"Unknown #3","source_recording_id":"rec_4f2a"}
```

---

## Integrating with an AI agent

The intended workflow: keep your agent pointed at the transcript files.

- **During a call** — open `live.md` in Claude Code / Cursor and ask "what have we decided so far?" The file grows as the meeting proceeds; the `pulsartrace:live` marker tells the agent the transcript is still provisional.
- **After a call** — `final.md` is the clean, speaker-labeled, finalized record. Ask your agent to "summarize the API design decisions" or "list every action item and who owns it."
- **Across calls** — an agent watching `events/*.jsonl` sees `final_md_written`, `speaker_renamed`, etc. and can keep its own index in sync. Speaker identity is keyed on the stable `spk_…` ID, so a rename never breaks references.

No plugin, no API key, no SDK — just files your tools already know how to read.

---

## Where things live on disk

| Path | Contents |
|---|---|
| `~/Library/Application Support/PulsarTrace/speakers.sqlite` | Speaker library (SQLite, WAL; `.bak` is the last-good backup) |
| `~/Library/Application Support/PulsarTrace/events/` | Events log, JSONL, 30-day retention |
| `~/Library/Caches/PulsarTrace/models/` | Downloaded whisper models |
| `~/Library/Logs/PulsarTrace/` | Operational logs, daily-rotated, 7-day retention |
| *(recording folder)* | `final.md`, `live.md`, `metadata.json`, `audio-*.wav` — written next to the input |

The operational log is for debugging and is safe to attach to a bug report — it never contains transcript text, speaker names, or full file paths.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  AudioFrameSource (protocol — 16kHz mono Float32 frames) │
│   FixturePlaybackSource · PipeSource · SocketSource      │
│   DeviceCaptureSource (planned, Epic 7)                  │
└───────────────────────────┬─────────────────────────────┘
                            ▼
┌─────────────────────────────────────────────────────────┐
│  Engine (Swift)                                          │
│   whisper.cpp (Metal)  ──▶ transcript + timestamps       │
│   pyannote (Python)    ──▶ speaker spans + embeddings    │
│   speaker library      ──▶ known names                   │
│        live pass ──▶ live.md     refine pass ──▶ final.md │
└─────────────────────────────────────────────────────────┘
```

The engine consumes an abstract `AudioFrameSource` — it cannot tell whether frames came from a microphone, a WAV file, a Unix socket, or a pipe. This is why the whole pipeline is buildable and testable without audio hardware, and why "bring your own audio" works: pipe PCM in and you get transcripts out.

- **Transcription** — whisper.cpp built with Metal, called via Swift FFI; the model stays resident.
- **Diarization** — `pyannote.audio` 4.x (`speaker-diarization-community-1`) in an embedded Python subprocess.
- **Speaker library** — SQLite with WAL journaling; voices matched by cosine similarity of pyannote embeddings, centroids refined by a running mean across appearances.

Architectural decisions and deviations from the original PRD are recorded in [`DECISIONS.md`](project-docs/DECISIONS.md).

---

## Project layout

```
Sources/PulsarTraceEngine/   Core library — audio sources, transcription,
                             diarization, speaker library, streaming, events
Sources/pulsartrace/         The `pulsartrace` CLI
Sources/pulsartrace-engine/  The streaming engine binary
Sources/CWhisper/            whisper.cpp C-API system-library wrapper
python/pulsartrace-ai/       Embedded Python — pyannote diarization
Tests/                       Unit / Pipeline / Capture test targets + fixtures
scripts/build-whisper.sh     Vendors + builds whisper.cpp
docs/                        file-format.md, events-schema.md, release-smoke-test.md
project-docs/                PRD.md, PLAN.md, DECISIONS.md — requirements,
                             implementation plan, architectural decisions
```

---

## Testing

```bash
swift test --filter Unit       # pure logic — fast, deterministic, no devices
swift test --filter Pipeline   # end-to-end on fixture audio (real whisper + pyannote)
swift test --filter Capture    # real-device tests; skip cleanly when no audio hardware
( cd python/pulsartrace-ai && .venv/bin/pytest )   # Python diarization layer
```

Pipeline tests run the real models against committed audio fixtures and snapshot the generated transcripts, so a regression in output format shows up as a text diff. Tests are deterministic (whisper temperature 0, seeded RNG, pinned model hashes). See [`docs/release-smoke-test.md`](docs/release-smoke-test.md) for the manual pre-release checklist.

---

## Roadmap

v0.1 (offline pipeline + streaming) is complete. Remaining milestones toward v1.0:

- **Epic 7 — Real device capture.** `pulsartrace-capture` daemon: microphone via AVFoundation, system audio via ScreenCaptureKit (no virtual audio device needed).
- **Epic 8 — Menubar app.** SwiftUI status item, start/stop, settings, speaker-library editor, live transcript preview.
- **Epic 9 — CLI surface.** `pulsartrace record`, `events tail`, `doctor`.
- **Epic 10 — Distribution.** Signed/notarized DMG, first-run permissions + Hugging Face token wizard.

---

## Privacy

Your audio never leaves your Mac. There is no telemetry, no analytics, no crash reporting that phones home, and no auto-update version checks. The **only** outbound network calls are first-launch model downloads — whisper models and the pyannote model, both from Hugging Face. After that, PulsarTrace works fully offline.

---

## License

MIT — see [`LICENSE`](LICENSE).

PulsarTrace builds on excellent open-source work: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT), [pyannote.audio](https://github.com/pyannote/pyannote-audio) (MIT), [PyTorch](https://github.com/pytorch/pytorch) (BSD), and [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) (MIT). The `speaker-diarization-community-1` model is distributed by pyannote under its own terms.
