# PulsarTrace — PRD

> **A small Mac tool that writes meeting transcripts to a markdown file.** Open source, local-only, plug your own AI agent into the file. Part of the Gravital Forge product family (sibling to OrbitNote).

## Meta

- **Status**: Draft
- **Scope**: New Product (0→1)
- **Platform**: macOS 14+ (Sonoma) on Apple Silicon (Intel best-effort)
- **License**: MIT (open source)
- **Distribution**: Signed/notarized DMG via GitHub Releases; Homebrew cask later
- **Business model**: Free and open source. Optional GitHub Sponsors / "buy me a coffee" link. A paid tier may be considered post-validation for power features (cloud sync of speaker library, larger model bundles, etc.); explicitly out of scope for v1.

---

## 1. Market Context

### Opportunity

Local meeting transcription with speaker labels is a category where every dominant solution (Otter, Fireflies, Granola, Fathom, Read.ai, Zoom AI Companion) ships audio to the cloud. For a meaningful slice of users — privacy-sensitive professionals, devs working on confidential systems, anyone under NDA, anyone who simply doesn't want their meetings on someone else's servers — this disqualifies the entire category.

The technical pieces to do this 100% locally on a Mac now exist and run well on Apple Silicon: whisper.cpp with Metal hits real-time on `large-v3`, pyannote/diart give state-of-the-art diarization, ScreenCaptureKit (macOS 14+) provides system audio capture without a virtual audio device. No single open-source tool stitches these together for non-researcher use.

The opportunity isn't to compete with Otter on UX. It's to be the obvious choice when "this conversation cannot leave my machine" is a hard requirement — and to be hackable enough that developers extend it rather than building their own from scratch.

### Competitive Landscape

| Tool | How they solve it | Strength | Weakness | Our angle |
|------|-------------------|----------|----------|-----------|
| Otter / Fireflies / Read.ai | Cloud transcription with bot in meeting | Polished UX, summaries, search | Audio leaves machine; subscriptions; meeting bots are intrusive | Strict local; no bot |
| Granola | On-device transcription, cloud features optional | Strong UX, growing | Closed source; cloud-tilted; macOS-native | Open source; integration via plain files |
| Aiko, MacWhisper, Whisper Transcription | Local Whisper wrappers | Local; simple | No diarization; no system audio capture; no cross-recording speaker memory | Diarization + speaker library |
| `transcribe-md` (the inspiration) | whisper.cpp + ScreenCaptureKit, mic vs system stream labeling | Lightweight; right capture stack | Chunked re-spawn loses audio; no real diarization; no speaker memory across recordings | Continuous capture; real diarization; persistent speaker library |
| DIY: WhisperX / pyannote scripts | Glue your own pipeline | Maximum flexibility | Hours of setup; no live mode; no UI | Pre-stitched; works out of the box; still hackable |

### Why now

- ScreenCaptureKit (macOS 14, Sept 2023) made loopback audio first-class — no BlackHole/Loopback dependency.
- pyannote 4.0 / community-1 (2025) closed much of the open-source vs. commercial diarization gap.
- whisper.cpp Metal hits real-time `large-v3` on M-series — what required a GPU server now runs on a laptop.
- Local-LLM-as-meeting-assistant is becoming a thing (Claude Code / Cursor users routinely point agents at files); shipping a tool that *writes a structured live file* is more useful than shipping yet another in-app chatbot.

---

## 2. Target User

### Primary persona: The Tinkerer Developer

- **Role**: Software engineer, ML engineer, technical founder, indie developer
- **Setup**: Apple Silicon Mac, comfortable with terminal, runs Homebrew, has Claude Code / Cursor / opencode / similar agent set up locally
- **Core pain**: Wants meeting transcripts but won't (or can't, for compliance) ship audio to a cloud service. Has tried Whisper wrappers; misses speaker labels. Has tried DIY pyannote scripts; hit the half-day setup wall.
- **Switching trigger**: A meeting they couldn't record because the cloud option was disqualified, OR seeing the GitHub repo on Hacker News / a colleague's recommendation.
- **Success = they can**: Record a 1:1 or group call with one menubar click, get a clean speaker-labeled markdown transcript, and have their AI agent of choice read that file to answer "what did we decide" mid-call or post-call.

### Secondary persona: The Privacy-Conscious Knowledge Worker

- Lawyer, therapist, journalist, consultant under NDA, founder discussing IP. Less technical but motivated enough to install a notarized DMG, grant permissions, and follow a one-page README.
- We don't *target* this persona for v1, but design choices shouldn't actively exclude them. A well-built menubar app for the developer naturally serves them too.

### Anti-personas (NOT for)

- Enterprise compliance buyers wanting SSO, SCIM, audit logs, central admin
- Teams wanting shared transcripts, real-time collaboration, comments
- Mobile-first users (no iOS/iPadOS in scope)
- Windows or Linux users (no in-scope)
- Users who want cloud LLM-generated summaries inside the app (we explicitly defer this to "point your own agent at the file")

---

## 3. Problem Statement

A developer joins a 1-hour technical call. They want a searchable transcript with speaker labels so they can later run their AI agent over it ("summarize the API design decisions"). Their options today:

- **Cloud meeting tools** disqualify the recording (NDA, internal IP, or simply preference).
- **Whisper wrappers** (MacWhisper, Aiko) transcribe but don't separate speakers — the transcript reads as one wall of text, useless for "who said the part about rate limits."
- **DIY pyannote + whisper** works but takes 2–6 hours of setup, breaks on the next macOS update, and doesn't capture system audio without extra plumbing.
- **The closest open-source reference** (`hrescak/transcribe-md`) demonstrates the right capture approach but loses audio between chunks (~500ms gaps from re-spawning ffmpeg + Swift binary every 10s) and has no real diarization or cross-recording speaker memory.

The core technical pieces all work; nobody has stitched them into a product where you click record, talk for an hour, and end up with a labeled transcript that's robust enough to actually trust.

### Evidence

- `hrescak/transcribe-md` exists with active interest despite being barely a week of work — there's appetite.
- HackerNews / Reddit /r/macapps regularly surface "best local transcription" threads with no clear "this one" answer.
- Granola (closed-source, partially cloud) has grown rapidly — the demand is clearly there; the local-only slice is underserved.
- pyannote.ai's community-1 announcement (45M monthly HF downloads of pyannote 3.1) confirms a large developer audience already pulling these models.

---

## 4. Goals & Success Metrics

This is open source with no business attached. Metrics are about adoption, quality, and signal that we built the right thing.

### Launch goals (first 90 days post-1.0)

| Metric | Target | How measured |
|--------|--------|--------------|
| GitHub stars | 1,000 | GitHub |
| HackerNews / Show HN | Front page once | Manual |
| Recording success rate | > 95% of started recordings produce a complete transcript | Telemetry-free: manual issue tracking |
| Speaker library accuracy (post-pass) | ≥ 90% of recurring speakers correctly auto-labeled by 3rd appearance | Manual eval on dogfooded recordings |
| Time-to-first-transcript for a new user | < 5 minutes from DMG download to first sentence appearing in a markdown file | User report / manual test on clean Mac |

### Quality bar (always-on)

- Live transcript lag: ≤ 5s behind real time (median)
- Live diarization label stability: a speaker's label doesn't flicker more than once per minute on average
- Post-call refinement: complete within 1× wall-clock of recording length on M-series
- Zero audio drops > 200ms during a recording
- Crash-free recording sessions: ≥ 99%

### Guardrails

- No telemetry, no analytics, no auto-updates, no network calls except first-launch model download from known hosts (Hugging Face, OpenAI's whisper.cpp model bucket). Violating this guts the entire premise.
- App bundle stays under 200MB excluding downloaded models.
- Should run comfortably on a 16GB Mac without thrashing during typical use.

---

## 5. Non-Goals (v1)

The single most important section. The temptation to build "the full vision" kills 0→1 products. For each item below, the answer is *deliberately* "not now."

- **Do NOT build an in-app LLM chat / summarization feature.** The product writes a clean markdown file; users plug their own agent into it. This is a feature, not an absence.
- **Do NOT support Windows or Linux.** macOS 14+ only.
- **Do NOT support iOS or iPadOS.** Mac only.
- **Do NOT support recording from a remote source / cloud meeting bot.** Capture is mic + system audio on the local machine, period.
- **Do NOT build a meeting calendar integration.** No "auto-record my Zoom calls." Recording starts when the user starts it.
- **Do NOT build cloud sync for transcripts or speaker library.** Everything stays on disk. (Plausibly a paid feature later; not v1.)
- **Do NOT build account / login / multi-user / sharing.** Single user, single Mac.
- **Do NOT build real-time collaboration on transcripts.** Files; that's it.
- **Do NOT build a custom audio player / waveform editor.** Output is markdown + the original audio file in standard formats. Users open audio in QuickTime / their tool of choice.
- **Do NOT support languages beyond what whisper supports out of the box.** No custom training.
- **Do NOT implement speaker enrollment via uploaded voice samples.** Speakers are learned by appearance over time. (Possible future feature.)
- **Do NOT build acoustic echo cancellation.** Use text-similarity dedup like `transcribe-md` does, plus diarization-based dedup once available.
- **Do NOT support recording-only mode without transcription.** If you just want audio, use QuickTime.
- **Do NOT implement custom whisper fine-tuning, LoRAs, or domain adaptation.** Use stock models.
- **Do NOT bundle a paid-tier upsell flow in v1.** GitHub Sponsors link in About is the maximum commercialization.

### The "one thing" test

If PulsarTrace could only do **one thing** well, what would it be?

> Produce a speaker-labeled, timestamped markdown transcript of a meeting, with the recording staying entirely on the user's Mac, and the transcript file usable by external AI agents in real time.

Everything else is in service of that.

---

## 6. Solution Overview

### Core insight

The product separates cleanly into two layers: a **stream-processing pipeline** (whisper + diart + speaker library + file output) and an **audio source layer** (mic, system audio, fixture playback, pipe, socket). The pipeline operates on an abstract `AudioFrameSource` — anything that produces PCM frames at real-time pace. Whether those frames came from `ScreenCaptureKit`, a WAV file played at real-time, or bytes piped in over a Unix socket, the pipeline cannot tell and does not care.

This separation means almost everything can be built and validated without touching real audio devices. Real device capture becomes the *last* epic rather than the foundation, and v0.1 ships as a file-in/file-out CLI — useful on its own, and a complete proof of the AI half before live capture is added.

The product is also two-pass: a **live pass** (provisional, optimized for latency, written to `live.md` so the user's AI agent can read it during the call) and a **refinement pass** (offline-quality, run after stop, the source of truth, replaces `live.md` with `final.md`). Mic stream is always "You"; system stream is diarized into one or more "Them"-speakers reconciled against a persistent speaker library that grows across recordings.

### The architecture

```
┌─────────────────────────────────────────────────────────────┐
│  AudioFrameSource (protocol — AsyncSequence<AudioFrame>)    │
│                                                              │
│   • DeviceCaptureSource    — AVFoundation / SCK             │
│   • FixturePlaybackSource  — WAV file at real-time pace     │
│   • PipeSource             — read PCM frames from stdin/fd  │
│   • SocketSource           — read PCM frames from UDS       │
└────────────────────────────┬────────────────────────────────┘
                             │ frames @ 16 kHz mono Float32
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                   Streaming engine                           │
│                                                              │
│  whisper streaming  ─────────► text + timestamps  ──┐       │
│  diart (sys stream only)  ────► speaker spans     ──┤       │
│  mic-echo dedup  ────────────► merged segments    ──┤       │
│                                                      ▼       │
│                                             append → live.md │
│                                                      │       │
│                          centroid lookup ──► known names    │
└─────────────────────────────────────────────────────────────┘

[on stop, refinement pass:]
audio-mic.wav  ──► whisper large-v3 ──► refined text  ──┐
audio-sys.wav  ──► whisper large-v3 ──► refined text  ──┤
                   offline pyannote  ──► speaker spans ──┼─► reconcile ─► final.md
                   centroid library  ──► speaker names ──┘
                   centroid update   ──► library write
```

### Why `AudioFrameSource` matters as a first-class primitive

This isn't just a testing abstraction — it's a product feature.

- **Determinism in tests.** `FixturePlaybackSource` produces the same frames every run. The entire pipeline is testable end-to-end without devices.
- **Streaming behavior under load is testable on any machine.** `ffmpeg -re -i fixture.wav -f f32le -ac 1 -ar 16000 - | pulsartrace-engine --stdin` exercises real-time pacing, real backpressure, real chunk-boundary behavior — on Linux, on EC2 Mac, anywhere — without audio devices.
- **Process isolation comes for free.** The capture daemon owns the OS audio APIs (and the only TCC permissions) and writes PCM to a Unix socket. The engine reads from the socket. Crash isolation: a capture crash doesn't kill mid-meeting transcription.
- **Replay is free.** A recorded WAV played through `FixturePlaybackSource` reproduces the exact bytes that hit the live pipeline. Bug from yesterday's meeting? Replay it through current code.
- **External capture sources become trivial.** Someone wants to feed audio from an iPhone, a Linux box, or a recorded Zoom meeting? Pipe PCM into the socket. Same engine, no special-case code.
- **"Bring your own audio" becomes a product story.** v0.1 is precisely this: file in, transcript out. The pipeline doesn't know whether bytes came from a recording you made years ago or from a meeting starting in 30 seconds.

### Architecture direction

- **Native macOS app, SwiftUI menubar interface, bundled CLI.** A single signed `.app` that contains:
  - SwiftUI host process (menubar UI, settings, speaker library editor)
  - `pulsartrace-engine` Swift binary (the streaming engine; consumes any `AudioFrameSource`)
  - `pulsartrace-capture` Swift binary (owns audio devices; writes PCM to a Unix socket — only process needing TCC grants)
  - `whisper.cpp` binary built with Metal
  - Embedded Python runtime (via [`python-build-standalone`](https://github.com/indygreg/python-build-standalone)) with pinned `pyannote.audio`, `diart`, `torch` (MPS)
  - `pulsartrace` CLI that orchestrates the above, suitable for headless use.

- **Why this stack over Tauri/Electron:** Capture *must* be Swift — ScreenCaptureKit and the cleanest AVFoundation paths are Swift-only. The AI pieces *must* be subprocesses regardless of host language (whisper.cpp is C++, pyannote is Python). A web-shell host adds a webview, IPC bridge, and JS runtime without eliminating any of the above. SwiftUI minimizes total moving parts: Swift for everything user-facing, subprocesses for the unavoidable C++ and Python.

- **Process model:**
  - **Menubar app** (long-lived, owns UI and user settings)
  - spawns → **pulsartrace-engine** (per recording session, owns the streaming pipeline)
  - which spawns → **pulsartrace-capture** (per recording session, owns audio devices)
  - **pulsartrace-capture writes PCM frames to a Unix domain socket; pulsartrace-engine reads from it.** This is the same socket interface that `FixturePlaybackSource` and `PipeSource` use in tests, just with a real device on the producer side.

- **Storage:** All artifacts under `~/Library/Application Support/PulsarTrace/` by default, user-configurable. One folder per recording: `audio-mic.wav`, `audio-system.wav`, `live.md`, `final.md`, `metadata.json`. Speaker library at `~/Library/Application Support/PulsarTrace/speakers.sqlite` (SQLite + numpy-blob centroids).

- **Models:** First-launch wizard downloads whisper `base` (~150 MB, multilingual) for live and `large-v3` (~3 GB, multilingual) for post-pass refinement, plus pyannote community-1. All multilingual by default — whisper auto-detects language per segment, no language picker needed. Cached under `~/Library/Caches/PulsarTrace/models/`. Model size is user-configurable; smaller machines can stay on `small` for both passes. **Pyannote community-1 requires a one-time Hugging Face account + token** (model is gated behind terms acceptance); first-launch walks the user through this with a link to the model page and a token-paste field.

- **Storage retention:** Recordings (audio WAVs, live.md, final.md, metadata.json) are kept indefinitely by default, in the user-chosen output folder. No automatic cleanup in v1; users delete what they don't need. Future versions may add age-based cleanup as an opt-in.

### Milestones

The work has two natural ship points:

- **v0.1 — Offline pipeline (CLI only).** Ships after Epics 1–5. A `pulsartrace refine path/to/audio.wav` command produces a speaker-labeled `final.md` with cross-recording speaker identity. No live mode, no menubar app, no real capture. Useful on its own for anyone with existing recordings; proves the AI half of the product before audio-stack risk is taken on. This is also the version that can be developed almost entirely on hardware that doesn't have working audio (EC2 Mac, VMs, Linux for the Python parts).
- **v1.0 — Live recording + UI.** Ships after Epics 6–10. Adds streaming transcription/diarization, real device capture, the menubar app, distribution. The full product as described in the User Flows section.

Each epic is "done" with tests against the abstraction layer; capture (Epic 7) is the only epic that requires real Mac audio access.

---

## 7. User Flows

### Flow A: First-run setup

1. User downloads `PulsarTrace.dmg`, drags to `/Applications`, opens it.
2. macOS prompts for Microphone permission (TCC). User grants.
3. App displays a one-screen welcome: "PulsarTrace needs Screen Recording permission to capture system audio. Click here to open System Settings." User grants Screen Recording, returns to app.
4. App explains the Hugging Face requirement: "The speaker-recognition model (pyannote community-1) is hosted on Hugging Face and requires a free account. Click to open the model page, accept the terms, then paste your access token below." Embedded button opens https://huggingface.co/pyannote/speaker-diarization-community-1 in browser; token-paste field with link to https://huggingface.co/settings/tokens. Token stored in macOS Keychain.
5. App offers model download choice (Small / Base / Large; defaults to "Base for live, Large for post-pass" with disk + RAM impact shown). User accepts. Models download in background.
6. App lands in idle state in menubar. Settings reachable from menubar.

**Target**: Permissions + model download started in < 90s of active user time (the HF account/token step is the rate-limiter; if user already has an HF account it's < 30s); first usable recording possible in < 5 min on typical home connection.

### Flow B: Record a meeting (the core flow)

1. User clicks PulsarTrace in menubar → "Start Recording".
2. Modal: choose mic (default: system default), choose output folder (default: last used), confirm system audio on/off (default: on). Optional: name the meeting (otherwise dated default).
3. Click "Record". Menubar icon shows recording indicator.
4. User joins their Zoom/Meet/whatever. Talks normally.
5. Behind the scenes: capture starts immediately, `live.md` file is created and starts filling, transcript appears in menubar popover and is appended to `live.md` in real time.
6. User can have Claude Code / Cursor / their agent open with `live.md` loaded; agent sees updates as they happen.
7. User clicks "Stop" in menubar (or hits global hotkey).
8. Recording stops. Menubar shows "Refining…" with progress.
9. Post-pass completes; `final.md` is written next to `live.md`. Menubar shows "Done." Notification fires.
10. User opens the meeting folder; sees both files plus the audio.

### Flow C: Speaker labeling (intermittent)

1. After a recording, in menubar → "Speaker Library".
2. List of speakers, with: name (or "Unknown #3"), # appearances, last seen, sample audio clip play button.
3. For unnamed speakers, user clicks "Name…" → enter name. Done.
4. Centroid is updated; future recordings auto-label this person.
5. Optional: merge two speakers (mistakenly split), split one (mistakenly merged), delete a speaker.

### Flow D: Replay / re-refine an old recording

1. User opens any past recording's folder. Right-clicks `final.md` or invokes from menubar → "Re-refine with current models".
2. Engine re-runs post-pass with current whisper + pyannote + speaker library.
3. New `final.md` overwrites the old (a `.bak` is kept).
4. Useful when the speaker library has grown (more speakers now nameable) or models have been upgraded.

### Flow E: Headless / scripted use

1. User invokes `pulsartrace record --output ~/meetings/today.md --duration 60m`.
2. CLI starts engine, writes live + final markdown, exits.
3. Composable in shell scripts and launchd plist for "always be ready to record."

---

## 8. Requirements

Prioritized **P0** (must ship in v0.1 or v1.0 milestone as appropriate) / **P1** (target for v1.0, droppable) / **P2** (post-v1).

### 8.1 Foundations & Stream Sources

The abstraction layer that everything else builds on. Implemented in Epic 1, before any production audio capture or AI work.

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R70 | P0 | `AudioFrameSource` Swift protocol exposing `AsyncSequence<AudioFrame>` of PCM frames at 16kHz mono Float32 | Protocol defined; engine consumes any conforming source |
| R71 | P0 | `FixturePlaybackSource` reads a WAV file and emits frames at real-time pace, with a "fast" mode for non-streaming tests | Pipeline tests use this; replay-from-WAV works |
| R72 | P0 | `PipeSource` reads PCM frames from a file descriptor (stdin or arbitrary fd) | `ffmpeg -re ... \| pulsartrace-engine --stdin` works end-to-end |
| R73 | P0 | `SocketSource` reads PCM frames from a Unix domain socket | Capture daemon writes; engine reads; same interface as fixtures |
| R74 | P0 | `DeviceCaptureSource` (Epic 7) implements the same protocol with real devices | Production uses this; no special-case engine code |
| R75 | P0 | All sources emit a clean termination signal (end-of-stream) the engine handles uniformly | Tests verify clean shutdown for each source type |
| R76 | P0 | Frame format is fixed: 16kHz mono Float32, framed at 20ms (320 samples) | Single canonical format; conversion happens at source boundary |
| R77 | P1 | Sources can be paused/resumed (for sleep/wake handling) | Pause emits a marker; resume continues; engine logs the gap |

### 8.2 Capture (real devices)

The `DeviceCaptureSource` implementation. Builds on the foundation laid in §8.1; the engine consuming these sources is identical to the engine consuming fixtures.

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R1 | P0 | `pulsartrace-capture` daemon captures default system microphone via AVFoundation, emits 16kHz mono Float32 frames | Continuous frame stream; no gaps > 200ms |
| R2 | P0 | `pulsartrace-capture` daemon captures system audio via ScreenCaptureKit, downmixes/resamples to 16kHz mono Float32 | Works without virtual audio devices (no BlackHole required in production) |
| R3 | P0 | Capture daemon writes both streams to a Unix domain socket using the same frame format the foundation layer specifies | Engine connects via `SocketSource`; pipeline behavior is identical to fixture-fed tests |
| R4 | P0 | Capture daemon is the *only* process requiring TCC permissions (Microphone + Screen Recording) | Engine has no TCC requirements |
| R5 | P0 | User selects non-default mic from picker | List populated from AVFoundation; selection persists |
| R6 | P0 | User can disable system audio capture | Engine receives only the mic stream; "Them" speaker spans absent from output |
| R7 | P1 | Recording survives system sleep / display sleep | Capture daemon emits pause/resume markers (R77); engine logs the gap in transcript |
| R8 | P1 | Recording survives audio-device change mid-session | Daemon switches to new default device; emits annotation marker; engine logs |

### 8.3 Transcription (offline and streaming)

Offline transcription (Epic 2 / v0.1) and streaming transcription (Epic 6 / v1.0) share the same whisper.cpp backend. They differ in pacing and output style.

**Offline (Epic 2):**

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R9 | P0 | Stream-process audio through whisper.cpp with the model resident in memory | Single whisper instance per source; no per-chunk model reload |
| R11 | P0 | Use overlap windowing or LocalAgreement-2 to avoid mid-word cuts at chunk boundaries | No more than 1 split-word artifact per 5 minutes on test corpus |
| R13 | P0 | Output format: `## Transcript YYYY-MM-DD HH:MM` header (local wall-clock, recorded once at session start), then per-utterance `**[HH:MM:SS] Speaker:** text` lines where `HH:MM:SS` is seconds-since-recording-started (00:00:00 → end-of-recording). Wall-clock metadata stored in `metadata.json` once. Avoids DST and timezone-shift edge cases mid-recording | Spec'd in Appendix |

**Streaming (Epic 6):**

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R10 | P0 | Live transcript lag ≤ 5s behind real time (median) on M-series | Measured on test corpus via `ffmpeg -re` fixture stream |
| R12 | P0 | Append to `live.md` atomically (no torn writes for downstream readers) | File never appears with partial UTF-8 character or partial line |
| R14 | P1 | Speaker labels in `live.md`: "You" for mic, "Them"/named speaker for system | Updated as diarization confirms |

### 8.4 Diarization (offline and streaming)

Offline diarization (Epic 3 / v0.1) is the source of truth; streaming diarization (Epic 6 / v1.0) is best-effort for live UX.

**Offline (Epic 3):**

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R15a | P0 | Run pyannote (community-1) offline on the full system stream WAV during post-pass | Speaker spans produced; embeddings extracted |
| R17 | P0 | Mic stream is *never* diarized; "You" is always "You" | No diarization runs on mic |

**Streaming (Epic 6):**

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R15 | P0 | Run `diart` on system stream during live capture | Speaker IDs appear in transcript with ≤ 3s lag from utterance |
| R16 | P0 | Live speaker IDs are working hypotheses; explicitly marked provisional in `live.md` (e.g., `*Them (provisional)*`) | Distinguishable from final labels |
| R18 | P1 | Live speaker library lookup: if a centroid exists matching the new speaker, display the known name (provisional but named) | Match threshold tunable; default 0.7 cosine |
| R19 | P0 | Mic-echo dedup: when speaker plays system audio out loud and mic picks it up, drop the mic-side duplicate | Text similarity > 0.5 within ±5s window between mic and system, drop mic side. (Carry over from `transcribe-md`.) |

### 8.5 Post-call refinement

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R20 | P0 | On stop, re-transcribe with `large-v3` (or user-configured larger model) | `final.md` produced |
| R21 | P0 | Run offline pyannote on system stream for global clustering | Speaker spans replace live diart spans |
| R22 | P0 | Reconcile post-pass speaker clusters with persistent speaker library by centroid match | Known speakers labeled by name; new speakers get "Unknown #N" placeholders |
| R23 | P0 | Update speaker library: add new centroids, refine existing ones with new audio | Library grows over time |
| R24 | P0 | Write `final.md` atomically; keep `live.md` as `.live.md.bak` | Both files present after refinement |
| R25 | P1 | Post-pass completes within 1× wall-clock of recording length on M-series | Measured on a 60min test recording |
| R26 | P1 | Post-pass runs in background; menubar shows progress; user can keep using machine | UI remains responsive |
| R27 | P2 | "Re-refine" command for old recordings using current models + library | Triggered from menubar or CLI |

### 8.6 Speaker library

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R28 | P0 | SQLite-backed speaker store: id, name, centroid (numpy blob), appearance_count, last_seen, sample_audio_path | Schema in Technical Context |
| R29 | P0 | Embeddings come from pyannote's pipeline (same model in live and post passes) | Embeddings cross-comparable |
| R30 | P0 | Centroid update: new appearance averages into existing centroid (running mean weighted by appearance_count) | Logic spec'd in Section 11 |
| R31 | P0 | Speaker library editor in menubar: list, name/rename, play sample, merge, split, delete | All five operations work |
| R32 | P1 | Centroid library is read-only during live pass (only post-pass writes) | Prevents bad live-clustering from polluting library |
| R32a | P0 | SQLite uses WAL journaling mode | Concurrent reader (live engine) + writer (post-pass or editor) is supported by SQLite natively; two concurrent writers are serialized by SQLite's lock with brief UI delay |
| R32b | P0 | Destructive library operations (merge, split, delete) are soft-deleted: a deleted/merged record is hidden but recoverable for 30 days via "Recently deleted" view | One-click undo toast appears after merge/split/delete |
| R33 | P2 | Manual speaker enrollment from a clip | Out of scope v1 |
| R34 | P2 | Export/import speaker library | Useful for moving between Macs; defer |

### 8.7 Live file as integration surface

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R35 | P0 | `live.md` is human-readable AND tool-readable plain markdown | A user pointing Claude Code / Cursor / opencode at `live.md` gets immediate value |
| R35a | P0 | `live.md` is created at session start (not first utterance) with `<!-- pulsartrace:live -->` marker and `## Transcript — YYYY-MM-DD HH:MM` header | Agents tailing the file get an unambiguous "recording is in progress" signal even before the first word |
| R36 | P0 | `live.md` writes are strictly append-only during live capture: no rewrites, no in-place edits, no replacements. Speaker renames during a recording take effect on the next post-pass, never on the live file | Tools watching the file via `tail -f` see strictly monotonic byte growth until post-pass replacement |
| R37 | P0 | A `<!-- pulsartrace:live -->` HTML comment marker in `live.md` distinguishes live-pass output | Lets agents detect "this is provisional" |
| R38 | P0 | After post-pass, the file is replaced with `final.md` AND a marker `<!-- pulsartrace:final -->` | Consumers can detect upgrade |
| R39 | P1 | A sidecar `metadata.json` describes speakers, durations, model versions | Machine-readable summary |

### 8.8 UI (menubar app)

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R40 | P0 | Menubar icon with status (idle / recording / refining) | Color-coded |
| R41 | P0 | Start/stop recording from menubar (incl. global hotkey) | Hotkey configurable |
| R42 | P0 | Settings: mic selection, model selection, output folder, hotkey, system audio on/off | All persisted |
| R43 | P0 | Speaker library editor (per R31) | All ops |
| R44 | P0 | Recordings list: past sessions with re-refine and reveal-in-finder. Source-of-truth is the user-configured output folder (and any previous output folders if changed): the menubar app scans for `metadata.json` files at app launch and on demand, no separate index database | Per recording. Moving a recording folder out of the configured location removes it from the list (documented behavior). |
| R45 | P1 | Live transcript preview popover from menubar (read-only scrolling view) | Updates in real time |
| R46 | P2 | Onboarding tour after first launch | Defer |

### 8.9 CLI

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R47 | P0 | `pulsartrace record [--output PATH] [--duration MIN] [--mic INDEX] [--no-system-audio] [--model MODEL]` | All flags work |
| R48 | P0 | `pulsartrace refine PATH` | Re-runs post-pass on an existing recording folder |
| R49 | P0 | `pulsartrace speakers list/rename/merge/delete` | Library mgmt from terminal |
| R50 | P1 | `pulsartrace doctor` validates dependencies, permissions, model presence | Outputs actionable diagnostics |
| R51 | P1 | CLI is symlinked into `/usr/local/bin` on app install (with user consent) | Prompted, not silent |

### 8.10 Permissions & install

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R52 | P0 | App is signed with a Developer ID and notarized | Gatekeeper passes without warnings |
| R53 | P0 | First-launch flow guides user through Microphone + Screen Recording grants | Both grants confirmed before recording is enabled |
| R54 | P0 | Permissions verification on every launch; clear remediation if revoked | Modal explains what's missing |
| R54a | P0 | Hugging Face token stored in macOS Keychain, validated against HF on save | Invalid tokens rejected at paste time, not at download time |
| R54b | P0 | HF token 401 during model download/refresh shows "Your Hugging Face token is invalid. Update it in Settings → Models" with a deep-link to the token-paste field | Cached models continue to work; only fresh downloads are blocked |
| R54c | P0 | Model downloads use HTTP Range requests and resume from partial state on retry | Interrupted 3GB download resumes from byte offset, doesn't restart from zero |
| R54d | P0 | Model downloads verify SHA-256 against pinned hashes after completion; mismatch deletes the file and prompts user to retry | No corrupted model is ever loaded into memory |
| R54e | P0 | Stored audio is 16kHz mono Int16 PCM WAV (~60 MB / hour). Resampling/downmixing happens at capture-source boundary | Per-recording storage size verifiable; sufficient quality for re-refinement |
| R55 | P2 | Homebrew cask | Post-1.0 |

### 8.11 Logging

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R57 | P0 | Daily-rotated plain-text log files at `~/Library/Logs/PulsarTrace/YYYY-MM-DD.log` | Files appear; old files (>7 days) deleted on launch and at midnight rotation |
| R58 | P0 | Default visible level = `notice` (lifecycle events + errors); `info`/`debug` off by default, toggle in Settings → Advanced | Defaults verified; toggle works |
| R59 | P0 | No audio bytes, no transcript text, no speaker names, no user file paths in any log line | Spot-check assertion in tests; manual review of a sample log |
| R60 | P0 | Python subprocess stderr piped into the same log file with `[python]` tag | Single grep finds Python errors alongside Swift errors |
| R61 | P1 | `os.Logger` mirror so `log show --predicate 'subsystem == "app.pulsartrace"'` works for Console.app users | Verified via `log` command |

### 8.12 Testing

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R62 | P0 | Three Swift test targets — `Unit`, `Pipeline`, `Capture` — runnable independently via `swift test --filter` | Each target runs in isolation |
| R63 | P0 | Stream source seam: `AudioFrameSource` protocol with `FixturePlaybackSource`, `PipeSource`, `SocketSource`, `DeviceCaptureSource` implementations (defined in §8.1) | Pipeline tests use `FixturePlaybackSource`; production uses `DeviceCaptureSource` via `SocketSource`; CLI tests pipe via `PipeSource` |
| R64 | P0 | Pipeline tests are deterministic: seeded RNG, whisper temperature 0, pinned model hashes, fixture audio in repo | Same fixture → same output across runs |
| R65 | P0 | Snapshot testing for all generated text artifacts (live.md, final.md, log lines, JSON sidecars) using `swift-snapshot-testing` | Format regressions show up as text diffs in CI/local |
| R66 | P0 | `Capture` target uses BlackHole 2ch when present; auto-skips with clear message when absent | Tests skip cleanly on machines without BlackHole |
| R67 | P0 | Python tests via `pytest` for the pyannote/diart wrapper layer | `pytest` runs from `python/pulsartrace-ai/` |
| R67a | P0 | IPC integration test: spawn `pulsartrace-engine` as subprocess, feed PCM frames over a real Unix domain socket from a fixture-driven stand-in (mimicking what `pulsartrace-capture` would write), assert engine output matches the in-process pipeline result | Catches frame-protocol regressions that in-process Pipeline tests can't see |
| R68 | P1 | `pulsartrace doctor --capture-test` end-to-end self-check (sine sweep through real capture path, frequency verification) | Run before each release |
| R69 | P1 | Manual smoke-test checklist in `docs/release-smoke-test.md` covering TCC re-grant, manual DMG upgrade, Gatekeeper first-launch, multi-mic switching | Used before tagging a release |

### 8.13 Events Log

A system-wide append-only JSONL log of significant events. Separate from the operational log (§8.11) — the operational log is for human debugging, the events log is a machine-readable API surface that LLM agents and external tools consume to understand "what's happened in PulsarTrace recently."

| ID | Pri | Requirement | Acceptance |
|----|-----|-------------|------------|
| R78 | P0 | JSONL events log at `~/Library/Application Support/PulsarTrace/events/YYYY-MM-DD.jsonl`, single combined stream (no per-type splitting) | One file per local day; events from all event types interleaved chronologically |
| R79 | P0 | Daily rotation, 30-day retention; older files deleted on launch and at midnight rotation | Files appear; old files (>30 days) deleted on schedule |
| R80 | P0 | Common envelope on every event: `ts` (ISO-8601 UTC), `type` (string), `id` (ULID), `version` (integer, starts at 1 per type) | Every line is a self-contained valid JSON object; missing fields = invalid event |
| R81 | P0 | Event types and payloads documented in `docs/events-schema.md`. Schema evolves per-type via the `version` field; consumers handle unknown future fields by ignoring them | A v1 consumer reading v2 events doesn't crash |
| R82 | P0 | Every significant operation in the product emits exactly one event. Categories: recording lifecycle, refinement lifecycle, speaker library mutations, file operations, system events | Coverage verified by listing event types vs. operations in the product |
| R83 | P0 | Stable internal speaker IDs (`spk_<ulid>`) are first-class in events. Renames change the `name` but never the `id`. Agents key off `id` for stable identity across time | Renaming "Unknown #3" to "Steve" produces a `speaker_renamed` event with `speaker_id` unchanged |
| R84 | P0 | Events log NEVER contains: audio bytes, transcript text, full user file paths (basename only). DOES contain: user-assigned speaker names, recording IDs, model names, file hashes | Privacy assertion same shape as the operational log's content-leak test (§11) |
| R85 | P0 | Events log is part of the public API surface alongside `live.md` and `final.md`. Format changes follow SemVer: additive fields are minor (no version bump); removed/renamed fields bump the per-type `version` | Documented in `docs/events-schema.md` as integrator contract |
| R86 | P1 | `pulsartrace events tail` CLI command for live-tailing today's events file with optional `--type` filter | `pulsartrace events tail --type speaker_renamed` works |

#### Event types

Documented fully in `docs/events-schema.md`. Initial set:

**Recording lifecycle**
- `recording_started` — `{recording_id, output_dir_basename, mic_device, system_audio_enabled, model_live}`
- `recording_paused` / `recording_resumed` — `{recording_id, reason}` (sleep, device_change)
- `recording_stopped` — `{recording_id, duration_seconds, reason}` (user_stop, force_quit, sleep_timeout, disk_full)

**Refinement lifecycle**
- `refinement_started` — `{recording_id, model_refine}`
- `refinement_completed` — `{recording_id, duration_seconds, speakers_identified, speakers_new, speakers_matched}`
- `refinement_failed` — `{recording_id, error_class, retry_available}`

**Speaker library**
- `speaker_created` — `{speaker_id, initial_name, source_recording_id}`
- `speaker_renamed` — `{speaker_id, old_name, new_name, applied_to_recordings}`
- `speaker_merged` — `{primary_speaker_id, merged_speaker_id, applied_to_recordings}`
- `speaker_split` — `{original_speaker_id, new_speaker_id, applied_to_recordings}`
- `speaker_deleted` — `{speaker_id, soft_delete: true, recoverable_until}`
- `speaker_undeleted` / `speaker_unmerged` / `speaker_unsplit` — undo operations
- `speaker_centroid_updated` — `{speaker_id, recording_id, appearance_count}`

**File operations**
- `live_md_started` — `{recording_id, path_basename}` (emitted when the file is created at session start, per R35a)
- `final_md_written` — `{recording_id, path_basename, sha256}` (first refinement)
- `final_md_rewritten` — `{recording_id, path_basename, sha256, reason}` (reason ∈ speaker_renamed, speaker_merged, speaker_split, speaker_undeleted, re_refine)
- `live_md_replaced_by_final` — `{recording_id}`

**System**
- `app_started` / `app_stopped` — `{version, macos_version}`
- `model_downloaded` — `{model_name, size_bytes, sha256, source_host}`
- `permission_changed` — `{permission, granted}` (TCC mic/screen)
- `library_backup_created` — `{path_basename, sha256}`
- `library_corruption_detected` — `{path_basename, recovered_from_backup}`

#### Example

```jsonl
{"ts":"2026-04-29T15:42:11Z","type":"refinement_completed","id":"evt_01HW...","version":1,"recording_id":"rec_4f2a","duration_seconds":48,"speakers_identified":3,"speakers_new":1,"speakers_matched":2}
{"ts":"2026-04-29T15:42:12Z","type":"speaker_created","id":"evt_01HW...","version":1,"speaker_id":"spk_a1b2","initial_name":"Unknown #3","source_recording_id":"rec_4f2a"}
{"ts":"2026-04-30T09:14:33Z","type":"speaker_renamed","id":"evt_01HX...","version":1,"speaker_id":"spk_a1b2","old_name":"Unknown #3","new_name":"Steve","applied_to_recordings":["rec_4f2a"]}
{"ts":"2026-04-30T09:14:33Z","type":"final_md_rewritten","id":"evt_01HX...","version":1,"recording_id":"rec_4f2a","path_basename":"final.md","sha256":"a3b1...","reason":"speaker_renamed"}
```

An LLM agent that processed `rec_4f2a` before the rename now sees the rewrite event and can either re-process the file or update its internal mapping from `spk_a1b2` → "Steve".

---

## 9. Edge Cases & Error States

PRDs that describe only the happy path produce code that fails the moment a real user touches it. State mapping for the core surfaces:

### Recording flow

| Scenario | Expected behavior |
|----------|-------------------|
| User clicks Record without granting Screen Recording permission | Modal: "PulsarTrace needs Screen Recording to capture system audio. Open Settings? [Open] [Mic-only this time]" |
| User clicks Record without granting Microphone permission | Modal: "PulsarTrace needs Microphone access. [Open Settings] [Cancel]" |
| Selected mic is unplugged before recording starts | Falls back to system default; log annotation in transcript |
| Selected mic is unplugged mid-recording | Capture continues on new default device; one-line annotation in transcript at the timestamp; menubar status icon flickers warning |
| User puts Mac to sleep mid-recording | Recording pauses gracefully; on wake, resumes; gap annotated in transcript with duration |
| User force-quits PulsarTrace mid-recording | Engine has been writing partial WAV with valid headers updated periodically (every 30s); recovery on next launch offers to refine the partial recording |
| Disk fills up during recording | Recording stops cleanly with a clear notification; what was captured up to the failure is preserved |
| User runs out of RAM (other apps) and engine is OOM-killed | Menubar app detects engine death; offers to recover partial recording |
| User starts a second recording while one is in progress | Only one allowed; menubar shows current; new attempt is rejected with "Already recording" |
| User unplugs headphones mid-call (now on speaker, mic picks up system audio) | Mic-echo dedup handles it; no user action |
| User has *very* quiet speakers and no one talks for 90s | Whisper VAD prevents hallucination; nothing is appended for that period |
| Recording exceeds 4 hours | Continues; no hard cap; warn at 4h that file size is getting large |

### Transcription / diarization

| Scenario | Expected behavior |
|----------|-------------------|
| Whisper hallucinates "thanks for watching" on silence | VAD-gated input prevents most; `[BLANK_AUDIO]` filter strips remainder |
| Speaker speaks a non-English language and model is `*.en` | Output may be poor; surfaced as warning if detected; user prompted to switch to multilingual model in settings |
| Two speakers talk over each other (overlap) | pyannote 4.0 community-1 handles overlap; both attributions appear in transcript |
| Speaker library has 200+ entries; live matching gets slow | Library lookup is in-memory cosine; should remain < 5ms even at 1000 speakers |
| Two distinct speakers' centroids are within threshold (sound similar) | False merge; user surfaces in library editor and clicks Split |
| One speaker's voice changes (cold, hoarse) and falls below threshold against own centroid | Spawns Unknown #N; user merges in library editor; centroid widens |
| Diart spawns 8 speaker IDs in a 2-person call | Provisional in live pass; post-pass corrects globally |

### Speaker library

| Scenario | Expected behavior |
|----------|-------------------|
| User renames a speaker mid-call | Rename takes effect on the next post-pass refinement; `live.md` keeps the original label until then. (Append-only invariant per R36 is preserved; no in-flight rewrites.) |
| User merges two speakers | All lines attributed to the merged speakers re-attributed; centroid is recomputed |
| User deletes a speaker | Past transcripts keep the name as a frozen string (not a live ref); future recordings won't auto-match |
| Library file is corrupted | Backup last good version on every write; auto-restore + warn |
| User wants to start over | Settings → Reset speaker library (with confirmation) |

### File / integration

| Scenario | Expected behavior |
|----------|-------------------|
| `live.md` is open in user's editor when post-pass tries to replace with `final.md` | Atomic rename; editor reloads file content; users notice the `<!-- pulsartrace:final -->` marker |
| User edits `live.md` manually mid-recording | Their edits get clobbered by next append. Documented in README: *don't edit live, edit final.* |
| External tool (Claude Code) holds a read on `live.md` | Append writes are non-blocking; reader sees consistent UTF-8 |
| Output folder is deleted while recording is in progress | Recording is recreated; warn in next user interaction |

### Permissions / install

| Scenario | Expected behavior |
|----------|-------------------|
| User installs unsigned dev build | Standard Gatekeeper warning; documented workaround in README |
| User updates macOS, TCC permissions reset | First-launch flow re-detects, walks user through re-granting |
| User runs on Intel Mac | Works but slow; warning shown that Apple Silicon is recommended |
| User runs on macOS 13 or earlier | App refuses to launch with clear "macOS 14 required" message |

---

## 10. Mac/Desktop Checklist Decisions

(Adapted from the SaaS checklist; SaaS-specific items dropped.)

| Item | Decision |
|------|----------|
| **Multi-tenancy** | ➖ N/A — single-user desktop app |
| **Permissions (macOS TCC)** | ✅ Microphone + Screen Recording, both required; first-launch flow handles |
| **Sandboxing** | ⚠️ Discuss: app sandbox would block writing to user-chosen folders without security-scoped bookmarks. Lean toward **non-sandboxed** for v1 (devs are fine with this; simplifies arbitrary file paths). Re-evaluate for App Store distribution post-v1. |
| **Code signing & notarization** | ✅ Required. Developer ID Application cert. |
| **Hardened runtime** | ✅ Required for notarization. Includes microphone + screen-capture entitlements. |
| **Auto-update** | ❌ None in v1. Releases are manual: user downloads new DMG from GitHub Releases. No Sparkle, no in-app update prompts, no version-check pings. (Revisit if user complaints about update friction become a thing.) |
| **Telemetry** | ✅ None. Hard requirement. (Update check is the *only* outbound network call beyond model download.) |
| **First-run model download** | ✅ Required; clear consent, progress, retry, integrity check (SHA-256 against known hashes). |
| **Crash reporting** | ✅ None that phones home. Crashes captured in local file logs (see Section 11) and macOS's standard crash report system. Users attach to GitHub issues manually. |
| **Logging** | ✅ Local file logs at `~/Library/Logs/PulsarTrace/`, daily-rotated, 7-day retention, error+notice by default. Full spec in Section 11. |
| **Events log** | ✅ Separate JSONL event log at `~/Library/Application Support/PulsarTrace/events/`, daily-rotated, 30-day retention. Public API surface for LLM agents / external tools. May contain user-assigned speaker names (local-only, never leaves device). Full spec in §8.13. |
| **Testing** | ✅ Local-only. Three targets (Unit / Pipeline / Capture), snapshot-tested text artifacts, BlackHole-driven real-capture tests on dev machine. Full strategy in Section 12. |
| **Performance: Apple Silicon vs Intel** | ✅ Apple Silicon is primary; Intel Macs supported but warned. Default models smaller on Intel. |
| **Memory** | ✅ Should run comfortably on a 16GB Mac. Live recording is light (`base` model + diart, ~1-2GB RSS). Refinement is heavier (`large-v3` + pyannote, expect 4-6GB RSS during post-pass). Documented in README so users with 8GB Macs know to use smaller models. |
| **Disk usage** | ✅ User-controlled output folder; warn when free space < 5GB. Models in `~/Library/Caches` (purgeable but with warning). |
| **Internationalization (UI)** | ⚠️ English-only UI in v1. Strings externalized (`Localizable.strings`) so community can add. |
| **Language support (transcription)** | ✅ Multilingual by default. Whisper auto-detects language per segment; default models (`base` for live, `large-v3` for refinement) are the multilingual variants. No language picker; no `*.en`-only defaults. Pyannote/diart are language-agnostic by design. |
| **Accessibility** | ⚠️ Menubar app + standard SwiftUI = mostly-free VoiceOver support. Live transcript popover needs explicit a11y labels. P1. |
| **Backup of speaker library** | ✅ Last-good-version on every write. P1: Time Machine respects default location. |
| **Privacy claims in copy** | ✅ "Your audio never leaves your Mac" is the headline. README explicitly enumerates the only network call: first-launch model download (whisper from Hugging Face / OpenAI's bucket, pyannote from Hugging Face). No update checks, no telemetry, no analytics. |
| **Open-source compliance** | ✅ MIT license. NOTICE file for whisper.cpp (MIT), pyannote (MIT), diart (MIT), torch (BSD). All compatible. |
| **Performance (live latency)** | ✅ Target ≤ 5s lag. Benchmarked before 1.0. |
| **Power consumption** | ⚠️ Continuous Whisper + diarization on a laptop is heavy. Document expected battery impact. P1: investigate whether smaller model + on-AC-only big-model logic is worth it. |
| **Donate / sponsor link** | ✅ GitHub Sponsors link in About dialog and README. No nag screens. |

---

## 11. Logging Specification

Logging is the primary debugging signal given the no-telemetry stance. It must be useful for diagnosing user-reported issues *and* safe to attach to a public GitHub issue without leaking content.

### File layout

```
~/Library/Logs/PulsarTrace/
  2026-04-30.log         ← today (current write target)
  2026-04-29.log
  2026-04-28.log
  2026-04-27.log
  2026-04-26.log
  2026-04-25.log
  2026-04-24.log         ← oldest kept
  (anything older deleted)
```

UTF-8 plain text, line-oriented, one event per line. Line format:

```
2026-04-30T14:30:05.123Z  notice  capture           Recording started; mic="MacBook Pro Microphone", system_audio=true, model=base, recording_id=rec_4f2a
2026-04-30T14:31:12.448Z  error   capture           ScreenCaptureKit stream failed; status=-3812; will retry once
2026-04-30T14:31:12.901Z  notice  capture           ScreenCaptureKit stream recovered after retry
2026-04-30T14:38:44.012Z  notice  refine            Post-pass started; recording_id=rec_4f2a, model=large-v3
2026-04-30T14:42:18.554Z  error   [python] pyannote Embedding model load failed: torch.cuda... (full traceback follows)
```

Columns: ISO-8601 UTC timestamp · level · subsystem (or `[python] subsystem`) · message.

### Rotation

- On app launch: scan `~/Library/Logs/PulsarTrace/`, delete any file older than 7 days, open today's file in append mode.
- At local midnight: close current file, open new one named for the new date, run the prune pass.
- Implementation: a single Swift `LogRotator` actor; ~50 lines.

### Levels and what gets logged

| Level | Default visible | What's logged |
|-------|-----------------|---------------|
| `error` | ✅ Yes | Caught exceptions, subprocess non-zero exits, permission denials, model load failures, IPC reconnects, file-write failures, library corruption. With detail: subsystem, error code, subprocess stderr tail (last ~500 chars), relevant non-PII identifiers (recording ID, model name). |
| `notice` | ✅ Yes | Session lifecycle: recording started/stopped, post-pass started/finished, model downloaded, library write, permissions granted/revoked, app version on launch, macOS version. One line each. |
| `info` | ❌ Off | Chunk-level events, IPC message summaries, file rotation events. On only when user toggles in Settings → Advanced. |
| `debug` | ❌ Off | Per-buffer diagnostics, embedding dimensions, full IPC payloads. On only for active troubleshooting. |

### What is NEVER logged

These are hard rules, enforced by code review and a unit test that scans test-run logs for forbidden content:

- Audio bytes or amplitudes that could reconstruct content
- Transcript text (any segment, any language)
- Speaker names from the user's library
- Full file paths chosen by the user (log only the basename or a hash if a path identifier is genuinely needed)
- Email addresses, app account names, or anything from the user's environment

For borderline cases use `os.Logger`'s `privacy: .private` annotation, which redacts in production builds:

```swift
logger.notice("Recording stopped, file=\(audioURL.lastPathComponent, privacy: .private)")
```

### Implementation

Stack: [`swift-log`](https://github.com/apple/swift-log) (Apple's logging protocol layer) with two backends wired in parallel:

1. **`OSLogHandler`** (community implementation) — bridges to `os.Logger`, so events show up in Console.app and `log show --predicate 'subsystem == "app.pulsartrace"'` for users comfortable with native Mac tools.
2. **Custom `FileLogHandler`** — writes to today's rotated log file with the line format above. Buffered, flushed on every `error` and every 5s otherwise, fsynced on app shutdown.

Python side: pyannote/diart use Python's standard `logging`. The engine subprocess's stderr is piped into the Swift log file by the parent process, with each line tagged `[python]` and preserved as-is (stderr already includes timestamp + level when configured properly on the Python side).

### Volume target

A typical user with 3 meetings/day produces well under 1MB of log per day at default levels. 7 days = under 10MB total — small enough to attach to a GitHub issue, small enough to not matter on disk.

### User-facing affordances

- Settings → Advanced → "Open Log Folder" reveals `~/Library/Logs/PulsarTrace/` in Finder.
- Settings → Advanced → "Verbose logging (next session)" toggle for `info`/`debug`.
- README documents how to grab the log when filing a bug, with a one-line `cat ~/Library/Logs/PulsarTrace/$(date +%Y-%m-%d).log` example.

---

## 12. Testing Strategy

This product will be substantially LLM-authored. That puts unusual weight on the test suite: humans don't reliably review every change, and an LLM "improving" something subtly is a real failure mode. The strategy below is local-first (no CI infrastructure required) and structured so that the suite *itself* tells the agent whether a change is safe.

### Layered structure

| Layer | Target | Speed | Determinism | Devices required |
|-------|--------|-------|-------------|------------------|
| **Unit** | `swift test --filter Unit` | <5s | Full | None |
| **Pipeline** | `swift test --filter Pipeline` | ~30s | Full | None |
| **Capture** | `swift test --filter Capture` | ~60s | Partial | BlackHole 2ch installed |
| **Python** | `pytest` from `python/pulsartrace-ai/` | ~20s | Full | None |
| **Manual smoke** | `docs/release-smoke-test.md` | ~5min by human | Human | Real Mac, fresh clone |

### Layer 1: Unit tests (Swift Testing framework)

The bulk of test code. Pure-functional logic: speaker library matching/merge/split, transcript timestamp merging, file format generation, mic-echo dedup, log rotation, IPC message encoding, settings persistence.

```swift
import Testing
@testable import PulsarTraceEngine

@Test("Speaker library matches existing centroid above threshold")
func speakerMatching() {
    let library = SpeakerLibrary.inMemory()
    let sarah = library.add(name: "Sarah", embedding: testEmbedding(.sarah))

    let match = library.findMatch(for: testEmbedding(.sarahSlightlyDifferent))

    #expect(match?.id == sarah.id)
    #expect(match!.similarity > 0.7)
}
```

Convention: one `#expect` per test where reasonable; LLMs do worse on tests asserting many things at once.

### Layer 2: Pipeline tests (fixture-fed, no real devices)

This is the layer that catches most regressions. Audio fixtures live in the repo (`tests/fixtures/audio/`), kept small enough to not need git LFS for v1:

```
tests/fixtures/audio/
  single-speaker-30s.wav         ← 480KB at 16kHz mono
  two-speakers-alternating.wav
  two-speakers-overlap.wav
  silence-then-speech.wav
  mic-and-system-paired/
    mic.wav
    system.wav
```

The stream source seam (R63, defined in §8.1) is what makes this layer real:

```swift
protocol AudioFrameSource {
    var frames: AsyncSequence<AudioFrame> { get }   // 16kHz mono Float32, 20ms framing
    func start() async throws
    func stop() async
}

// Production (Epic 7 — real audio devices)
final class DeviceCaptureSource: AudioFrameSource { /* AVFoundation + ScreenCaptureKit, runs in pulsartrace-capture daemon */ }

// IPC (production engine reads frames written by the capture daemon)
final class SocketSource: AudioFrameSource {
    init(socketPath: URL) { /* read length-prefixed PCM frames from a Unix domain socket */ }
}

// Pipe (CLI / external tools — `ffmpeg -re ... | pulsartrace-engine --stdin`)
final class PipeSource: AudioFrameSource {
    init(fd: Int32) { /* read PCM frames from a file descriptor */ }
}

// Tests (and replay)
final class FixturePlaybackSource: AudioFrameSource {
    init(file: URL, realtime: Bool = true) { /* read WAV, emit at real-time pacing or fast */ }
    func simulateInterruption(duration: TimeInterval) { /* sleep/wake */ }
}
```

Tests drive the *entire pipeline above the source* — chunking, whisper, diarization, file rotation, IPC, mic-echo dedup — using `FixturePlaybackSource`. Outputs are snapshot-tested:

```swift
@Test("Two-speaker recording produces stable speaker labels")
func twoSpeakerDiarization() async throws {
    let engine = PulsarTraceEngine.test(seed: 42)
    let result = try await engine.refine(
        systemAudio: fixture("two-speakers-alternating.wav"),
        micAudio: nil
    )
    assertSnapshot(of: result.markdown, as: .lines)
}
```

[`swift-snapshot-testing`](https://github.com/pointfreeco/swift-snapshot-testing) records the output on first run and diffs on subsequent runs. Format regressions an LLM might introduce ("I made the timestamps friendlier") become visible diffs.

### Layer 3: Capture tests (BlackHole on dev machine)

Exercises the real `AVFoundation` and `ScreenCaptureKit` paths, deterministically, without polluting the dev's actual audio output.

Approach: a test helper plays a fixture WAV via `AVAudioEngine` from a child process, the test configures `SCContentFilter(includingApplications: [helperPID])` to capture only that process's audio, captures for N seconds, and asserts on the captured WAV's properties (duration, sample count, channel layout, low-resolution audio fingerprint).

```swift
@Test("ScreenCaptureKit captures audio from a target PID")
func systemAudioFromPID() async throws {
    try BlackHole.requireInstalled()  // skips test gracefully if not installed

    let player = try TestAudioPlayer(file: fixture("sine-440hz-5s.wav"))
    try player.start()

    let capture = DeviceCaptureSource(systemAudioFilter: .pid(player.pid))
    let captured = try await capture.captureAndSave(duration: 5)

    #expect(captured.duration.isApproximately(5, tolerance: 0.1))
    #expect(captured.dominantFrequency.isApproximately(440, tolerance: 5))
}
```

Setup cost: ~one afternoon getting the first BlackHole-based test reliable. After that, every subsequent capture test is a small variant of the first.

Mic capture is intentionally *not* covered at this layer — testing it requires routing BlackHole as default input, which pollutes the dev's machine more invasively. AVFoundation's mic path is the most stable component in this stack and is covered by the protocol-seam tests in Layer 2 plus manual smoke tests.

### Layer 4: IPC integration tests

The `capture.sock` binary frame protocol (PCM frames flowing from `pulsartrace-capture` to `pulsartrace-engine`) is a contract that in-process Pipeline tests don't exercise — `FixturePlaybackSource` skips the socket entirely. A frame-protocol regression could pass `swift test --filter Pipeline` and only fail in production.

The IPC layer is covered by a small set of integration tests that:

1. Spawn `pulsartrace-engine` as a subprocess listening on a temp socket.
2. Run a fixture-driven stand-in that reads a WAV and writes frames to the socket using exactly the same protocol `pulsartrace-capture` uses (length-prefixed PCM, 20ms framing per R76).
3. Assert engine output matches the in-process Pipeline test on the same fixture.

These don't need real audio devices; they need only fork/exec and a Unix socket. They live in the `Pipeline` target with an `IPC` filter (`swift test --filter Pipeline.IPC`) and are run alongside the regular pipeline tests.

### Layer 5: Python tests (pytest)

The pyannote/diart wrapper code. Same audio fixtures (loaded by absolute path from the Swift test fixtures dir). Verifies that the Python layer's outputs (speaker spans, embeddings) match what the Swift layer expects at the IPC boundary.

### Layer 6: Manual smoke tests

A short checklist in `docs/release-smoke-test.md`, run by a human before tagging each release. Covers things automation genuinely can't:

- TCC permission grant flow on a fresh user account
- TCC re-grant after macOS update reset
- Hugging Face token paste flow + model download from a fresh state
- Manual DMG upgrade from previous version (download, replace, ensure speaker library + settings persist)
- Gatekeeper first-launch on a Mac that's never seen the app
- Mid-session mic switch (unplug headphones)
- Mid-session sleep/wake
- Disk-full handling (mount a tiny disk image)

5 minutes of clicking. LLMs can't run it; humans don't forget if it's a checklist.

### Determinism rules (non-negotiable)

For pipeline tests to be useful, they must produce the same output every run. Hard rules enforced by code review:

- Whisper temperature = 0 in test invocations.
- All RNG (torch, numpy, Python `random`) seeded explicitly per-test.
- Model versions pinned by hash in `Package.resolved` and `requirements.lock`.
- Fixture audio committed to repo, never regenerated at test time.
- Wall-clock time mocked when tests interact with rotation logic.

When a snapshot test fails, the LLM's first instinct will be to update the snapshot. Code review must flag any snapshot update as a deliberate change requiring justification, not a fix.

### LLM workflow

The intended development loop:

1. LLM makes a change.
2. `swift test --filter Unit && swift test --filter Pipeline` — must pass.
3. If touching capture: `swift test --filter Capture` — must pass.
4. If touching Python: `pytest python/pulsartrace-ai/` — must pass.
5. If touching log format, file format, IPC: review snapshot diffs deliberately.
6. Human runs manual smoke checklist before each release tag.

This gives substantial confidence that LLM-authored changes haven't broken anything observable, without requiring a human to manually verify every PR.

---

## 13. Distribution & Licensing

- **License**: MIT. Simple, well-understood, no patent grant (acceptable for this project; no patentable IP being defended).
- **Repo**: Single GitHub monorepo on a personal account for v1. `apps/pulsartrace-mac` (SwiftUI app), `swift/pulsartrace-engine` (Swift engine library), `python/pulsartrace-ai` (pyannote/diart wrapper), shared `protocol/` for the IPC schemas.
- **Binary distribution**: GitHub Releases with `PulsarTrace-x.y.z.dmg` and SHA-256 checksums. Notarized.
- **Updates**: Manual. No Sparkle, no in-app update prompts, no version-check pings. Users learn about new versions from the GitHub releases page or release-announcement channels of their own choosing.
- **Homebrew cask**: post-1.0.
- **Mac App Store**: explicit non-goal for v1 (sandboxing complexity, model bundling rules).
- **Versioning**: SemVer. Breaking changes to the `live.md` / `final.md` format bump major.
- **Public API surface for integrators**: three things, all plain text on disk:
  1. `live.md` per recording — append-only stream, live transcription
  2. `final.md` per recording — refined transcript, the source of truth
  3. `events/*.jsonl` — system-wide event log, 30-day retention, JSONL format
  
  Tools like Claude Code, Cursor, opencode read whichever combination fits their workflow. Format changes follow SemVer; breaking changes to any of the three bump the major version. Documented formally in the repo at `docs/file-format.md` and `docs/events-schema.md`.

---

## 14. Go-to-Market Direction

For an open-source project with no business model attached, "GTM" is really "how do users discover this and why does it land?" Lots of OSS ships and silently dies; the launch plan is cheap insurance.

### Launch strategy

- **Phase**: Private soft-launch (friends, OrbitNote audience) → public Show HN → submit to /r/macapps and /r/LocalLLaMA → blog post on Gravital Forge → submit to Awesome-Mac and similar curation lists.
- **Initial audience signal**: developer-leaning Mac users who already self-host or care about local-first tooling. The opener line should be "Local meeting transcription with speaker labels. Plug your AI agent at the file. Open source." — not "another transcription app."
- **Channel**: Product-led. No sales motion. The README is the marketing surface.

### What product needs for launch

- **README that opens with a 30-second value statement**, a 90-second install-and-run, and a clearly-marked example `final.md` so visitors immediately see the output shape.
- **One-page docs site** at gravitalforge.com/pulsartrace or similar, mostly screenshots and the file-format reference.
- **A demo recording on GitHub Releases page** — a 5-minute sample with the resulting `final.md` so people can preview without installing.
- **A clearly named integration recipe** (~half-page) showing exactly how to wire `live.md` into Claude Code, Cursor, and opencode. The integration story is the differentiator; show it concretely.

### Launch-day requirements

- The macOS 14+ requirement is prominent. Don't bury "Sonoma required" three scrolls down — it's a near-instant filter for half the visitors and that's fine.
- A short FAQ covering: "Why do I need a Hugging Face account?", "Does this work on Intel Macs?" (yes but slow), "Does this work offline after first launch?" (yes, fully), "Why isn't this in the App Store?" (sandbox + bundled Python).
- The Anti-persona ("not for enterprise teams wanting SSO/SCIM") is in the FAQ too — keeps inappropriate-fit inquiries from cluttering issues.

### What's explicitly NOT launch-day-required

- No newsletter. No Twitter presence. No Discord server. Issues + Discussions on GitHub is the entire community surface for v1.

---

## 15. Epic Breakdown

Ten epics, dependency-ordered, organized into two milestones:

- **v0.1 (CLI-only, file-in/file-out):** Epics 1–5. Ships as a `pulsartrace refine` command that takes a WAV and produces a speaker-labeled `final.md`. Useful on its own; provable on hardware without working audio devices.
- **v1.0 (live + UI):** Epics 6–10. Adds streaming, real device capture, the menubar app, and distribution.

**Tests and logs are part of every epic, not a separate epic.** Each epic ships its production code together with its tests and logging. An epic is not "done" until tests pass and log output has been reviewed for content leaks. The shared infrastructure that makes this work (test target structure, snapshot testing, fixture conventions, `AudioFrameSource` protocol with all four implementations, `swift-log` setup, log rotation, IPC scaffolding) is set up at the very start of Epic 1, before any production AI code is written. Every later epic inherits and extends those conventions.

### v0.1 milestone — Offline pipeline (Epics 1–5)

#### Epic 1: Foundations

The infrastructure layer everything else builds on. No production audio capture yet, no AI yet — just the seams.

- Project structure: SwiftUI app target (skeleton only), `pulsartrace-engine` Swift binary, Python package skeleton with `python-build-standalone` runtime build script, three Swift test targets (`Unit`, `Pipeline`, `Capture`), Python `pytest` setup. **Note:** `pulsartrace-capture` is NOT created in this epic — it first becomes necessary in Epic 7. v0.1 (Epics 1–5) never invokes it.
- `swift-log` with dual backends (`os.Logger` + custom file logger), daily rotation, 7-day retention, content-leak unit test scaffolding.
- **Events log infrastructure**: append-only JSONL writer with daily rotation (30-day retention), ULID generation for event IDs, the common envelope contract (`ts`/`type`/`id`/`version`), and the first event types (`app_started`/`app_stopped`). Later epics extend the event-type registry.
- **`AudioFrameSource` protocol** with three implementations: `FixturePlaybackSource` (real-time WAV pacing), `PipeSource` (read PCM from stdin/fd), `SocketSource` (read PCM from Unix domain socket). `DeviceCaptureSource` is deferred to Epic 7.
- Audio fixtures (`tests/fixtures/audio/`), `swift-snapshot-testing` wired up.
- IPC scaffolding: `control.sock` (JSON-line protocol for engine/UI handshake) and `capture.sock` (binary frame protocol — definition only, no real producer yet).
- BlackHole detection helper for the (currently empty) `Capture` target.
- "Hello world" tests in each target proving the harness works.

- **Dependencies**: None
- **Requirements**: R70–R77 (stream sources), R57–R67, R67a (logging + testing infrastructure foundations), R78–R85 foundational coverage (events log infrastructure + envelope; specific event-type emission lands in the relevant later epic)
- **Edge cases owned**: snapshot-test drift from nondeterminism; BlackHole detection on developer machines; fixture-audio repository size growth; log directory permission denied; midnight rotation race; events log file is open when rotation fires.
- **"Done" looks like**: `swift test --filter Unit && swift test --filter Pipeline` is green in <30s; `pytest python/pulsartrace-ai/` is green; an `ffmpeg -re ... | pulsartrace-engine --stdin` end-to-end smoke (just consumes and counts frames) works; an `app_started` and `app_stopped` event pair appears in today's `events/*.jsonl` after a clean launch and exit. No real audio devices touched anywhere.

#### Epic 2: Offline Transcription

Whisper.cpp wired up, consuming from any `AudioFrameSource`. Used in fast (non-real-time) fixture mode for this epic — streaming behavior is Epic 6. Resident model (no per-call reload), Metal acceleration, multilingual `base` and `large-v3` model support, model download + integrity verification.

- **Dependencies**: Epic 1
- **Requirements**: R9, R11, R13 (offline whisper + format). Model download requirements R54c, R54d also land here since whisper is the first model that needs downloading. R54e (audio storage format) — establish the canonical Int16 WAV format used end-to-end.
- **Edge cases owned**: whisper hallucinates "thanks for watching" on silence (VAD-gated input + `[BLANK_AUDIO]` filter); language mismatch warning when `*.en` model used on non-English audio; chunk-boundary words; very quiet input → no hallucinated text; recording exceeds 4 hours; speaker speaks a non-English language and model is `*.en`.
- **"Done" looks like**: `pulsartrace-engine --source fixture meeting.wav --transcribe` produces a markdown transcript matching a snapshot.

#### Epic 3: Offline Diarization

pyannote (community-1) wired up, runs on a WAV file via the embedded Python runtime. Produces speaker spans with embeddings extracted. Engine merges transcript + speaker spans by timestamp. No live mode yet.

- **Dependencies**: Epic 2
- **Requirements**: R15a (offline pyannote on system stream), R17 (mic never diarized), R29 (embeddings come from pyannote's pipeline)
- **Edge cases owned**: two speakers talk over each other (pyannote 4.0 handles overlap); single-speaker recordings (pyannote degrades gracefully — should not spawn ghost speakers); pyannote model version mismatch with stored library embeddings.
- **"Done" looks like**: a fixture WAV produces a markdown transcript with `**[HH:MM:SS] Speaker_0:**` lines stable across runs.

#### Epic 4: Refinement Pipeline (`pulsartrace refine`)

The full offline command: WAV → text → speaker spans → reconciled markdown. Atomic file writes, metadata sidecar, model version tracking. **This is the v0.1 product** — `pulsartrace refine path/to/audio.wav` produces a complete `final.md`. No live mode, no menubar, no real capture.

- **Dependencies**: Epics 2, 3
- **Requirements**: R20 (re-transcribe with large-v3), R21 (offline pyannote on system stream), R24 (atomic final.md writeout, .bak preserved), R25 (post-pass timing), R26 (background execution + progress), R27 (re-refine command), R38 (post-pass file marker), R39 (metadata.json sidecar). Emits events: `refinement_started`, `refinement_completed`, `refinement_failed`, `final_md_written`, `final_md_rewritten` (on re-refine), `live_md_replaced_by_final`.
- **Edge cases owned**: file replacement while editor is open (atomic rename, editor reloads); partial-recording recovery (engine crashed mid-recording — partial WAV with periodic header updates); very long recordings (>4h, RAM/swap pressure); low-quality input (no usable speech detected — return empty final.md with explanatory marker); model upgrades changing output format (versioned snapshots).
- **"Done" looks like**: a fresh user with whisper + pyannote installed runs `pulsartrace refine meeting.wav` and gets a working `final.md`. **This is v0.1 ship-able.**

#### Epic 5: Speaker Library

SQLite-backed persistent centroid library. CLI-only management at this stage (`pulsartrace speakers list / rename / merge / delete`). Cross-recording matching via cosine similarity. Library is integrated into the refinement pipeline: post-pass clusters are reconciled against the library, known names auto-applied, new speakers given Unknown #N placeholders.

- **Dependencies**: Epic 4
- **Requirements**: R22 (reconcile clusters against library), R23 (update library), R28 (schema), R30 (centroid running-mean update), R32a (WAL mode), R32b (soft delete with 30-day undo). R49 partial (CLI subcommands for speakers). Stable internal IDs (`spk_<ulid>`) per R83. Emits events: `speaker_created`, `speaker_renamed`, `speaker_merged`, `speaker_split`, `speaker_deleted`, `speaker_undeleted`, `speaker_unmerged`, `speaker_unsplit`, `speaker_centroid_updated`, `library_backup_created`, `library_corruption_detected`.
- **Edge cases owned**: centroid drift over time (running-mean smooths but masks real change); two distinct speakers' centroids fall within threshold (false merge — surface "Recently merged" with undo); voice changes (cold, hoarse — spawns Unknown #N, user merges later); library corruption (last-good backup on every write, auto-restore + warn); library file too large (>10k speakers — performance check); two concurrent writers (SQLite WAL handles, brief UI delay).
- **"Done" looks like**: refining a second recording with a returning speaker auto-applies the name set after the first recording.

### v1.0 milestone — Live + UI (Epics 6–10)

#### Epic 6: Streaming Transcription & Diarization

Whisper streaming (LocalAgreement-2 or whisper.cpp's `stream` mode) and `diart` for live speaker IDs, both consuming from any `AudioFrameSource`. Atomic append to `live.md`, mic-echo dedup, provisional speaker labels, library lookup in read-only mode (writes still happen only in post-pass per R32).

Critically, this epic is testable end-to-end without real devices: pipe `ffmpeg -re fixture.wav` into the engine via `PipeSource`, or use `FixturePlaybackSource` with real-time pacing.

- **Dependencies**: Epics 4, 5
- **Requirements**: R10 (live transcript lag ≤5s), R12 (live.md atomic appends), R14 (speaker labels in live.md), R15 (diart on system stream), R16 (provisional marker), R18 (library lookup in read-only mode), R19 (mic-echo dedup), R32 (library read-only during live), R35 (live.md tool-readable), R35a (created at session start with marker + header), R36 (strictly append-only), R37 (live marker). Emits events: `live_md_started`.
- **Edge cases owned**: chunk-boundary words straddling 10s windows (overlap windowing + dedup on seam); real-time backpressure (whisper slow → buffer grows); diart spawns 8 speaker IDs in a 2-person call (provisional, OK — post-pass corrects); mic-echo on shared speakers (text similarity dedup); whisper hallucinates "thanks for watching" on silence; speaker speaks non-English language (warning surfaced); voice changes during session (live spawns new speaker, post-pass reconciles).
- **"Done" looks like**: `ffmpeg -re fixture.wav | pulsartrace-engine --stdin --live` produces a `live.md` that grows in real time, with provisional speaker labels that resolve correctly after a subsequent `pulsartrace refine`.

#### Epic 7: Real Device Capture

The `DeviceCaptureSource` implementation. `pulsartrace-capture` Swift binary that owns AVFoundation (mic) and ScreenCaptureKit (system audio), writes PCM frames to a Unix domain socket. The engine connects to that socket via `SocketSource` and proceeds exactly as in fixture-fed tests.

**This is the only epic that requires a real Mac with working audio.** It plugs into the protocol seam established in Epic 1 — there is no "integrate with engine" step, because the engine doesn't know it's now talking to a real device.

- **Dependencies**: Epic 1 (protocol), Epic 6 (streaming consumer to integrate with)
- **Requirements**: R1–R8 (capture daemon). Emits events: `recording_started`, `recording_paused`, `recording_resumed`, `recording_stopped`, `permission_changed`.
- **Edge cases owned**: user clicks Record without granting Screen Recording (modal with deep-link to Settings; mic-only fallback offered); without Microphone grant (modal); selected mic unplugged before recording (fallback to default); selected mic unplugged mid-recording (continue on new default, log annotation); Mac sleeps mid-recording (pause + resume on wake, gap annotated); user force-quits PulsarTrace mid-recording (partial WAV with valid header, recovery offer on next launch); disk fills up during recording (clean stop, what was captured is preserved); engine OOM-killed (menubar detects death, offers recovery); user unplugs headphones mid-call (mic-echo dedup handles); recording exceeds 4 hours (continue, warn about file size); TCC denial mid-session (engine receives error from daemon, stops cleanly).
- **"Done" looks like**: `pulsartrace record --duration 5m` records a real meeting and produces both a `live.md` and a refined `final.md` matching what fixture-fed tests would produce on equivalent audio.

#### Epic 8: Menubar UI

SwiftUI menubar app wrapping the engine: status icon, start/stop, settings (mic, model, output folder, hotkey, system-audio toggle), recording history, live transcript popover, speaker library editor. Renames in the editor apply to all past `final.md` files (rewrite + atomic replace); `live.md` of an in-progress recording is never modified retroactively (append-only per R36 — renames take effect at the next post-pass).

- **Dependencies**: Epics 5, 7 (engine + capture)
- **Requirements**: R31 (library editor: list/rename/merge/split/delete/play sample), R40–R46 (menubar UI including R44's scan-output-folder behavior and R45's live transcript popover)
- **Edge cases owned**: engine crash mid-recording (menubar detects, offers recovery from partial WAV); user attempts to start a second recording while one is in progress (rejected with "Already recording"); permissions revoked mid-session (modal explains, recording stops cleanly); user renames a speaker mid-call (effect deferred to next post-pass per R36); user merges two speakers (retroactive rename across past `final.md` files, soft-deleted record recoverable per R32b); user deletes a speaker (soft delete with undo toast); empty state for Speaker Library editor (no speakers yet — show "Record a meeting to get started"); empty state for Recordings list (no past recordings — show "No recordings yet" with quick-start CTA); user moves a recording folder out of the configured location (silently disappears from list — documented behavior per R44); long speaker names / Unicode / emoji in names (formatter handles); concurrent library write from editor + post-pass refinement (SQLite WAL serializes, brief UI delay).
- **"Done" looks like**: a user can do the entire core flow end-to-end without ever touching a terminal.

#### Epic 9: CLI Surface

Full `pulsartrace` CLI: `record`, `refine`, `speakers`, `doctor`. `pulsartrace record` orchestrates `pulsartrace-capture` + `pulsartrace-engine` for headless use. Includes `pulsartrace doctor --capture-test` self-check (R68).

- **Dependencies**: Epic 7 (capture), Epic 8 (settings/library code paths to reuse)
- **Requirements**: R47 (record), R48 (refine), R49 (speakers — completes the management surface started in Epic 5), R50 (doctor), R51 (CLI symlink to /usr/local/bin with consent), R68 (doctor capture-test), R86 (`pulsartrace events tail`)
- **Edge cases owned**: missing permissions in headless mode (clear stderr message, exit code); missing models in headless mode (offer download, refuse if non-interactive); library corruption detected by doctor (offer auto-restore from .bak); user runs `pulsartrace record` on Intel Mac (warn but proceed); user runs on macOS 13 (refuse with clear message); CLI invoked while menubar is also running (share engine socket, don't spawn duplicate).
- **"Done" looks like**: `pulsartrace record --duration 60m --output meeting.md` works without the menubar app running.

#### Epic 10: Distribution & First-Run

Signing, notarization, first-run permissions wizard (TCC + Hugging Face token paste), model-download flow, integrity verification (SHA-256 against pinned hashes), About panel with sponsor link. Includes the manual smoke-test checklist (R69) since it gates releases. **No auto-update mechanism**: releases ship as new DMGs on GitHub Releases.

- **Dependencies**: Epics 8, 9 (something to ship)
- **Requirements**: R52 (signed + notarized), R53 (first-launch permissions wizard), R54 (permissions verification on every launch), R54a (HF token in Keychain), R54b (HF token revocation handling), R55 (Homebrew cask, P2), R69 (smoke checklist). Emits events: `model_downloaded`.
- **Edge cases owned**: TCC reset after macOS update (re-detect, walk user through re-granting); user installs unsigned dev build (Gatekeeper warning, README workaround); user runs on Intel Mac (works but slow, warning); user runs on macOS 13 or earlier (refuse with clear message); HF token revoked by user externally (R54b modal); model download interrupted (R54c resumable); model SHA mismatch on download (R54d delete + retry); first-launch flow on a fresh user account; Migration Assistant moves the app to a new Mac (TCC re-grant needed, library + settings preserved if backup is restored).
- **"Done" looks like**: a fresh Mac → DMG → working first recording in < 5min, with a notarized binary; the smoke-test checklist exists and has been executed for the 1.0 release.

---

## 16. Open Questions

| # | Question | Owner | Blocks |
|---|----------|-------|--------|
| 1 | Diart vs. windowed-pyannote for live: both discussed, both viable. Diart is purpose-built for streaming but online clustering is less accurate; windowed is more accurate but adds ~30s lag. **Recommendation: ship diart for v1; revisit if quality complaints come in.** | Eng | Epic 6 |
| 2 | Should mic-echo dedup always be on, or only when no headphones detected? Detecting headphones is possible via CoreAudio. **Recommendation: always on for v1; the false-positive rate is low and the mental model is simpler.** | Eng | Epic 6 |
| 3 | Speaker library format stability: SQLite schema is internal but centroid embeddings are tied to the pyannote model version. What's our migration story when pyannote updates? Likely: keep the model version string in the library, refuse to match across versions, force user to re-name speakers on first run after a model upgrade. | Eng | Epic 5 |
| 4 | App Store viability: assume notarized DMG only for v1; revisit App Store post-1.0 once architecture stabilizes? | PM | Epic 10 |
| 5 | Should `final.md` also include a JSON sidecar with speaker timing data (for richer downstream tooling)? Currently P1 (R39). | PM | Epic 4 |
| 6 | Donation/sponsor: GitHub Sponsors only, or also Open Collective / Buy Me a Coffee? Defer to post-launch. | PM | Epic 10 |
| 7 | Hard constraints not yet captured (Intel Mac support level? Air-gapped first-launch?) | PM | Various |

### Resolved (kept here for traceability)

- **Product name**: PulsarTrace. Sibling to OrbitNote in the Gravital Forge product family. Pulsar = a precise, repeating signal that observers record (literally what astronomical pulsar timing arrays do); trace = the recorded path that signal leaves over time. The name maps cleanly onto the product: a meeting emits a signal, PulsarTrace traces it to a markdown file. CLI binary and component names use the full `pulsartrace` form (e.g., `pulsartrace refine`, `pulsartrace-engine`, `pulsartrace-capture`) — explicit over short to avoid collisions with existing tools like `the_platinum_searcher`'s `pt`.
- **License**: MIT.
- **Engine language**: Swift, not Rust.
- **Default live model**: `base` (multilingual). No `*.en` defaults anywhere.
- **Default refinement model**: `large-v3` (multilingual).
- **Multilingual default behavior**: whisper auto-detects language per segment; no language picker.
- **Speaker centroid drift strategy**: running mean (simple). Revisit if it underperforms.
- **Battery behavior**: work normally on battery; no auto-downgrade. User picks smaller model manually if needed.
- **Auto-update**: none. Manual DMG download from GitHub Releases.
- **Telemetry**: zero.
- **Sponsor link prominence**: GitHub Sponsors link in About + README only. No nudges.
- **Pyannote model gating**: accept the friction; first-launch wizard walks user through HF account + token.
- **Audio retention**: keep indefinitely in v1; revisit cleanup later.
- **Repo location**: personal GitHub account.

---

## 17. Technical Context (for downstream planner agent)

### Stack

- **macOS host app**: Swift 5.10+, SwiftUI, AppKit interop where needed, deployment target macOS 14.0.
- **Central abstraction**: `AudioFrameSource` Swift protocol exposing `AsyncSequence<AudioFrame>` of 16kHz mono Float32 frames at 20ms framing. All four implementations (`DeviceCaptureSource`, `FixturePlaybackSource`, `PipeSource`, `SocketSource`) live in the engine library and are interchangeable from the engine's perspective.
- **Process model**:
  - `PulsarTrace.app` (SwiftUI menubar host, long-lived)
  - spawns → `pulsartrace-engine` (per-session, owns the streaming pipeline; consumes any `AudioFrameSource`)
  - which spawns → `pulsartrace-capture` (per-session, owns AVFoundation + ScreenCaptureKit; the **only** process needing TCC permissions; writes PCM frames to a Unix domain socket)
  - The CLI (`pulsartrace`) orchestrates the same engine + capture binaries headlessly.
- **Transcription**: `whisper.cpp` built with `-DGGML_METAL=ON`, invoked via `pywhispercpp` Python bindings OR direct C++ FFI from Swift (decision in Epic 2). Models: `ggml-base.bin` (multilingual, ~150MB) and `ggml-large-v3.bin` (multilingual, ~3GB) by default. `*.en` variants are optional but not the default.
- **Diarization**: `pyannote.audio >= 4.0` (community-1 model) for offline; `diart >= 0.10` for live. Both via embedded Python.
- **Embedded Python**: `python-build-standalone` 3.12, with `torch` (MPS-enabled), `pyannote.audio`, `diart`, `numpy`, `scipy` pinned. Bundled inside the .app at `Contents/Resources/python/`.
- **Storage**: SQLite (via Swift's GRDB or built-in `sqlite3`) for speaker library; flat files (WAV, Markdown, JSON) for recordings.
- **IPC**: Two distinct Unix domain sockets per session:
  - `capture.sock` — `pulsartrace-capture` writes PCM frames; `pulsartrace-engine` reads via `SocketSource`. Binary frame protocol (length-prefixed, 16kHz mono Float32 at 20ms framing per R76).
  - `control.sock` — JSON-line protocol between menubar app / CLI and engine for control messages (start, stop, status, progress).
- **Build**: Xcode for the Swift parts; the Python venv built via a script run as part of the Xcode build phase.

### Relevant existing systems / inspiration

- `hrescak/transcribe-md` is the reference implementation for the *capture* layer (Swift + ScreenCaptureKit + ffmpeg-AVFoundation). Lift the Swift ScreenCaptureKit helper directly; rewrite the Python orchestrator from scratch (chunk-respawn is the main thing to fix).
- `m-bain/whisperX` is the reference for separating transcription and diarization as parallel async streams merged by timestamp.
- `juanmc2005/diart` is the live diarization runtime.
- `pyannote/speaker-diarization-community-1` is the current best open-source diarization model.

### Conventions

- All Swift code follows Swift API Design Guidelines.
- All Python code follows ruff + black defaults.
- All file I/O uses atomic write-then-rename for files external tools may be reading.
- All subprocess invocations have explicit timeouts and stderr capture.
- All long-running operations report progress via the IPC protocol; UI never polls.
- Logs go to `~/Library/Logs/PulsarTrace/` with daily rotation.

### Agent boundaries (for the coding agent that consumes this PRD)

- ✅ **Always**: Use the capture approach from `transcribe-md` as a starting reference for Swift ScreenCaptureKit code (Epic 7). Pin all model and library versions exactly. Write the live-file format spec as a separate file (`docs/file-format.md`) so external integrators can rely on it. **Maintain the events log schema at `docs/events-schema.md` and emit the correct event for every significant operation** (§8.13). Reuse pyannote's embedding model in both live and post-pass paths. **Ship tests with every epic**, written against the conventions established in Epic 1. **Log lifecycle events at `notice` and failures at `error`**, never log content (audio/transcript/full paths). Run `swift test --filter Unit && swift test --filter Pipeline` before declaring a non-capture change done; add `swift test --filter Capture` for capture changes. **All audio sources MUST conform to `AudioFrameSource`** — never write engine code that assumes a specific source.
- ⚠️ **Ask first**: Switching engine language from Swift to Rust. Choosing diart vs windowed-pyannote (Open Question #2). Adding any new outbound network endpoint. Bundling additional models beyond whisper + pyannote. Updating an existing snapshot (`__Snapshots__/*`) — this is a contract change, not a fix. Adding a new `AudioFrameSource` implementation — the four in Epic 1 should cover all v1 needs.
- 🚫 **Never**: Introduce telemetry. Send audio off-device. Embed a closed-source dependency. Change the `live.md` / `final.md` format without a major version bump and a migration note. Change an event-type's schema in a breaking way without bumping its `version` field. Write to the speaker library from the live pass. Log audio bytes, transcript text, or full user file paths (in either the operational log or the events log). Ship a change to capture, file format, IPC, the speaker library, or the events log without a corresponding test. **Bypass the `AudioFrameSource` abstraction — engine code that calls `AVAudioEngine` or `SCStream` directly is a bug regardless of test pass/fail.** **Emit a speaker rename / merge / split without also emitting the corresponding `final_md_rewritten` event** — these must always be paired so external agents see the chain of causation.

### Appendix: file format spec (for R13, R37, R38)

```
<!-- pulsartrace:live -->
## Transcript — 2026-04-30 14:30

**[14:30:05] You:** So the main issue is the authentication flow breaks on mobile.

**[14:30:12] Sarah (provisional):** Right, I think the redirect URI isn't being handled correctly by the webview.

...
```

After post-pass, the marker becomes `<!-- pulsartrace:final -->` and `(provisional)` annotations are removed. Format is line-oriented; consumers can `tail -f` it.

