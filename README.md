# PulsarTrace

**Local-only meeting transcription with speaker labels. Plug your AI agent into the file. Open source.**

PulsarTrace turns a meeting recording into a clean, speaker-labeled Markdown transcript — and it never sends your audio anywhere. Transcription (on the Apple Neural Engine — Parakeet live, WhisperKit refine) and speaker diarization (pyannote community-1 on CoreML) run entirely on your Mac. The output is plain Markdown and JSONL on disk, designed to be read by your AI agent of choice (Claude Code, Cursor, opencode, …) during or after the call.

Part of the Gravital Forge product family (sibling to OrbitNote).

---

## Status

> **v0.1 — offline pipeline, live streaming, and a menubar app.** Buildable and usable today as a command-line tool or an unsigned dev-build menubar app.

| Capability | State |
|---|---|
| Offline refinement (`pulsartrace refine`) — audio → speaker-labeled `final.md` | ✅ Working |
| Streaming transcription + live diarization → append-only `live.md` | ✅ Working |
| Persistent speaker library — recognizes recurring voices across recordings | ✅ Working |
| Events log (`events/*.jsonl`) — machine-readable activity stream | ✅ Working |
| Real microphone / system-audio capture (`pulsartrace-capture`) | ✅ Working |
| Headless CLI — `pulsartrace record`, `doctor`, `events tail`, `install-cli` | ✅ Working |
| Menubar app — record, settings, speaker editor, live transcript preview, global hotkey, notifications | ✅ Working (unsigned dev build) |
| Signed/notarized DMG, first-run permissions wizard | ⏳ Planned (Epic 10) |

PulsarTrace is a complete **command-line tool** today: record a meeting with `pulsartrace record`, or feed it an existing WAV with `pulsartrace refine`. A **menubar app** (`pulsartrace-mac`) drives the same flow without a terminal — it runs today as an unsigned dev build. A signed/notarized DMG and a first-run permissions wizard are the remaining milestone — see [Roadmap](#roadmap). The entire AI pipeline is built and tested against an audio-source abstraction, so most of it builds and runs without touching audio hardware.

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
- **Homebrew** with `ffmpeg`:
  ```bash
  brew install ffmpeg
  ```
- ~2 GB free disk for models (Parakeet live ~500 MB, WhisperKit refine `large-v3-turbo` ~626 MB / `large-v3-whisperkit` ~947 MB; diarization CoreML bundles ~21 MB). CoreML model bundles download automatically on first use.

---

## Build & setup

```bash
git clone <repo-url> gravital-pulsar-trace
cd gravital-pulsar-trace

# Build the Swift binaries
swift build            # add -c release for production speed
```

Transcription and diarization both run on the Apple Neural Engine — Parakeet
(FluidAudio) for the live pass, WhisperKit for the refine pass, and FluidAudio's
CoreML diarizer (pyannote community-1) for speaker spans. There is no native
build step and no Python: the CoreML model bundles download automatically on
first use (see project-docs/DECISIONS.md D39, D40).

This produces four binaries under `.build/debug/` (or `.build/release/`):

- **`pulsartrace`** — the user-facing CLI (`record`, `refine`, `speakers`, `doctor`, `events tail`, `install-cli`)
- **`pulsartrace-engine`** — the streaming engine (consumes any audio source)
- **`pulsartrace-capture`** — the device-capture daemon (microphone + system audio)
- **`pulsartrace-mac`** — the menubar app; run it as a dev `.app` via `scripts/make-dev-app.sh` (a bare `swift run` shows no menu-bar item)

Transcription and diarization models (Parakeet + WhisperKit + speaker-diarization CoreML bundles) download automatically on first use into `~/Library/Caches/PulsarTrace/models/`.

---

## Quick start

A 60-second tour. From the repo root:

### 1. Record a meeting → `final.md`

`pulsartrace record` captures your microphone and system audio, writes a live
transcript, and refines it when you stop — no UI, no other tools:

```bash
.build/debug/pulsartrace record --duration 30 --output meeting
# or run untimed and press Ctrl-C to stop:
.build/debug/pulsartrace record --output meeting
```

It records for `--duration` minutes (or until Ctrl-C), then transcribes and
diarizes into `meeting/final.md`. `--list-mics` prints the input devices for
`--mic INDEX`; `--no-system-audio` records the microphone only. First, check
the environment is ready:

```bash
.build/debug/pulsartrace doctor              # macOS, models, permissions, …
.build/debug/pulsartrace doctor --capture-test  # play a tone, verify capture
```

### 2. Refine an existing recording → `final.md`

```bash
# Convert any audio to the canonical format first if it isn't already a WAV:
ffmpeg -i meeting.mp3 -ar 16000 -ac 1 -c:a pcm_s16le meeting.wav

.build/debug/pulsartrace refine meeting.wav
```

This transcribes, diarizes, reconciles speakers against the library, and writes a recording folder next to the input:

```
meeting/
  final.md         ← speaker-labeled transcript (the source of truth)
  metadata.json    ← speakers, durations, model identity
```

Refine uses WhisperKit's `large-v3-turbo` model by default. Pass `--model large-v3-whisperkit` for the slower, larger accuracy-fallback model.

### 3. Watch a live transcript being written

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

### 4. Manage the speaker library

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

**[00:00:12] Them?:** Right, the redirect URI isn't handled.
```

The `<!-- pulsartrace:live -->` / `<!-- pulsartrace:final -->` marker lets a consumer tell a provisional transcript from a finalized one. Provisional `?` labels are resolved in the refinement pass.

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
| `~/Library/Caches/PulsarTrace/models/` | Downloaded transcription models (Parakeet + WhisperKit CoreML bundles) |
| `~/Library/Logs/PulsarTrace/` | Operational logs, daily-rotated, 7-day retention |
| *(recording folder)* | `final.md`, `live.md`, `metadata.json`, `audio-*.wav` — written next to the input |

The operational log is for debugging and is safe to attach to a bug report — it never contains transcript text, speaker names, or full file paths.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  AudioFrameSource (protocol — 16kHz mono Float32 frames) │
│   FixturePlaybackSource · PipeSource · SocketSource      │
│   DeviceCaptureSource (microphone + system audio)        │
└───────────────────────────┬─────────────────────────────┘
                            ▼
┌─────────────────────────────────────────────────────────┐
│  Engine (Swift)                                          │
│   ANE ASR (Parakeet/WhisperKit) ──▶ transcript + times   │
│   ANE diarizer (FluidAudio CoreML) ──▶ spans + embeddings│
│   speaker library      ──▶ known names                   │
│        live pass ──▶ live.md     refine pass ──▶ final.md │
└─────────────────────────────────────────────────────────┘
```

The engine consumes an abstract `AudioFrameSource` — it cannot tell whether frames came from a microphone, a WAV file, a Unix socket, or a pipe. This is why the whole pipeline is buildable and testable without audio hardware, and why "bring your own audio" works: pipe PCM in and you get transcripts out.

- **Transcription** — runs on the Apple Neural Engine: Parakeet TDT (FluidAudio) for the live pass, WhisperKit for the refine pass; the model stays resident. See [`DECISIONS.md`](project-docs/DECISIONS.md) D39.
- **Diarization** — FluidAudio offline diarization (CoreML/ANE) — speaker spans + embeddings in-process. Runs FluidInference's CoreML conversion of `pyannote/speaker-diarization-community-1` (segmentation + WeSpeaker embeddings + VBx/PLDA clustering). See [`DECISIONS.md`](project-docs/DECISIONS.md) D40.
- **Speaker library** — SQLite with WAL journaling; voices matched by cosine similarity of WeSpeaker embeddings, centroids refined by a running mean across appearances.

Architectural decisions and deviations from the original PRD are recorded in [`DECISIONS.md`](project-docs/DECISIONS.md).

---

## Project layout

```
Sources/PulsarTraceEngine/   Core library — audio sources, transcription,
                             diarization, speaker library, streaming, events
Sources/PulsarTraceCapture/  Device-capture library — AVFoundation mic +
                             ScreenCaptureKit system audio
Sources/PulsarTraceMenuBar/  Menubar library — @Observable ViewModels & state
Sources/pulsartrace/         The `pulsartrace` CLI
Sources/pulsartrace-engine/  The streaming engine binary
Sources/pulsartrace-capture/ The device-capture daemon binary
Sources/pulsartrace-mac/     The menubar app (SwiftUI MenuBarExtra)
Tests/                       Unit / Pipeline / Capture / MenuBar test targets
                             + fixtures
scripts/make-dev-app.sh      Wraps `pulsartrace-mac` in a launchable dev `.app`
docs/                        file-format.md, events-schema.md, release-smoke-test.md
project-docs/                PRD.md, PLAN.md, DECISIONS.md — requirements,
                             implementation plan, architectural decisions
```

---

## Testing

```bash
swift test --filter Unit       # pure logic — fast, deterministic, no devices
swift test --filter Pipeline   # end-to-end on fixture audio (real ANE models)
swift test --filter Capture    # real-device tests; skip cleanly when no audio hardware
swift test --filter MenuBar    # menubar ViewModels — settings, scanner, speaker editor
```

Pipeline tests run the real ANE models (Parakeet / WhisperKit / FluidAudio diarizer) against committed audio fixtures and assert on distinctive fixture keywords, so a regression in output shows up as a failed assertion. See [`docs/release-smoke-test.md`](docs/release-smoke-test.md) for the manual pre-release checklist.

---

## Roadmap

v0.1 (offline pipeline + streaming), real device capture, the full CLI, and the menubar app are complete. One milestone remains toward v1.0:

- ✅ **Epic 7 — Real device capture.** `pulsartrace-capture` daemon: microphone via AVFoundation, system audio via ScreenCaptureKit (no virtual audio device needed).
- ✅ **Epic 9 — CLI surface.** `pulsartrace record`, `doctor` (+ `--capture-test`), `events tail`, `install-cli`.
- ✅ **Epic 8 — Menubar app.** SwiftUI `MenuBarExtra` — start/stop, settings, speaker-library editor, live transcript preview. A retroactive speaker rename rewrites every past `final.md`. Runs today as an unsigned dev build (`scripts/make-dev-app.sh`).
- **Epic 10 — Distribution.** Signed/notarized DMG, first-run permissions wizard.

---

## Privacy

Your audio never leaves your Mac. There is no telemetry, no analytics, no crash reporting that phones home, and no auto-update version checks. The **only** outbound network calls are first-launch model downloads — the transcription and diarization CoreML bundles (Parakeet + WhisperKit + speaker-diarization), all from public Hugging Face repos (no account or token needed). After that, PulsarTrace works fully offline.

The same posture holds on disk: transcripts, recordings, `metadata.json`, the events log, and the speaker library are written readable by your user account only (`0600` files, `0700` for the directories PulsarTrace creates), and looser permissions left behind by older versions are repaired. The Unix sockets PulsarTrace's own processes use to move audio between them verify that the connecting peer is the same user and reject anyone else.

---

## License

MIT — see [`LICENSE`](LICENSE).

PulsarTrace builds on excellent open-source work: [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0, runs Parakeet TDT and the speaker diarizer on the ANE), [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (MIT), [pyannote.audio](https://github.com/pyannote/pyannote-audio) (MIT), and [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) (MIT). The `parakeet-tdt-0.6b-v3` model is distributed under CC-BY-4.0; the diarization models are FluidInference's CoreML conversion of `pyannote/speaker-diarization-community-1`, distributed by pyannote under its own terms.
