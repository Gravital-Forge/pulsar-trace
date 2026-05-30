# Whisper Subprocess — Recovery From Unrecoverable Decode Wedges

- **Status:** design — not yet implemented (branch `feat/whisper-wedge-followups`)
- **Date:** 2026-05-26
- **Scope:** `pulsartrace-engine` (live whisper) + `pulsartrace-mac` (refinement whisper). New binary `pulsartrace-whisper`. Capture daemon unchanged.
- **Supersedes:** the abort-callback recovery path in `docs/specs/2026-05-22-live-pipeline-decoupling-design.md` §11 — empirically confirmed insufficient (see Problem).

## 1. Problem

The decoupling work (2026-05-22) made recording safe from whisper wedges — but did not recover live transcription. The 2026-05-26 wedge is the worst-case instance:

```
20:54:07.246Z warning engine  whisper decode exceeded deadline; aborting stream=system
20:54:12.285Z → 20:57:43.419Z warning engine  whisper decode did not honor abort; age=5039ms → 216175ms past abort signal, stream=system
20:57:43.431Z notice  engine  live pass finished — 383 line(s)
```

The watchdog fired on schedule, called `token.cancel()`, logged the escalating "did not honor abort" warning 3,948 times over 3:36 — the decode never honored the abort. Live transcription was dead from 20:54:07 (24:13 into the recording) until the user manually stopped the recording at 20:57:33. **The recording itself survived** (WAVs grew the full 27:36), proving the decoupling fix's recording-safety guarantee. **Live transcription did not recover** because we have no mechanism to forcibly free the wedged decode without killing the engine subprocess.

### Why the abort_callback approach is structurally insufficient

`whisper_full_params.abort_callback` is only polled at encode/decode-STEP boundaries in this build of whisper.cpp — not between ggml graph nodes. When a decode wedges *inside* a graph compute (which is what happened), the abort signal never takes effect. This was documented as a known limitation in `2026-05-22-live-pipeline-decoupling-design.md` §11 when we built it; 2026-05-26 is the first production confirmation that it bites.

### Why in-process recovery is also structurally insufficient

The wedged decode runs on a `DispatchQueue.global` thread holding the process-wide `metalLock` (`WhisperTranscriber.swift:99`). We cannot:

- `pthread_cancel` it safely — a thread cancelled mid-Metal-command-buffer leaves the GPU driver in an undefined state.
- `whisper_free` the context while a thread is inside it (use-after-free).
- Build a second `whisper_context` and use it concurrently — whisper.cpp does not guarantee two contexts on one Metal device behave correctly, and the wedged decode's GPU command queue is in an unknown state.

### Why killing the engine subprocess is also structurally insufficient

The engine subprocess owns the WAV writers (`StreamingWAVWriter`), the capture-socket consumer, the live.md writer, and the events writer. Killing the engine = audio recording stops mid-frame, capture's one-shot `accept()` loop terminates on EPIPE (`CaptureSocketServer.swift:119`), live.md writes stop. **Recording loss is exactly what the decoupling work prevented and must remain prevented.**

### Conclusion

Whisper inference must move into a separate process from the audio-recording pipeline, so it can be SIGKILL'd cleanly without disturbing recording.

## 2. Goals / Non-goals

**Goals**

- G1 (must): the recording is never blocked or truncated by a whisper wedge — same invariant as `2026-05-22-live-pipeline-decoupling-design.md` G1, preserved.
- G2 (must): a wedged live decode is recoverable within seconds — live transcription resumes without a manual recording stop.
- G3: a wedged refinement decode is recoverable without losing already-completed regions — the existing resumable-region design already handles partial restart.
- G4: at most one whisper subprocess runs at any time — both by lifecycle design AND a structural OS-level safeguard.
- G5: no persistent whisper process when no transcription is running — the live model (`base`) and the refinement model (`large-v3`) are loaded on demand and unloaded at end-of-work.

**Non-goals**

- Moving VAD into the subprocess. Silero VAD is fast (~1MB model), doesn't wedge in observed runs, and keeping it in-process keeps the IPC surface narrow.
- Hot-swapping models inside a single long-lived whisper subprocess. B-3 is achieved instead by per-workload subprocess lifecycle (spawn on first use, kill when done).
- Cross-workload priority/QoS. Refinement yields to recording via the existing `pauseForRecording` mechanism; we extend it, not redesign it.

## 3. Architecture

### Processes today

```
pulsartrace-mac    ── owns refinement queue, UI, lifecycle
  └─ spawns RecordOrchestrator on Start Recording
       ├─ pulsartrace-capture   ── audio capture, UDS server
       └─ pulsartrace-engine    ── reads capture UDS, drain+WAV+live.md+events+diarization+WHISPER
```

The wedged whisper lives in `pulsartrace-engine` and takes live transcription down with it.

### Processes after

```
pulsartrace-mac    ── owns refinement queue, UI, lifecycle
  ├─ spawns pulsartrace-whisper(--model=large-v3) when refinement queue has work
  └─ spawns RecordOrchestrator on Start Recording
       ├─ pulsartrace-capture                 ── unchanged
       └─ pulsartrace-engine                  ── unchanged except whisper moves out
            └─ spawns pulsartrace-whisper(--model=base) at recording start
```

The engine subprocess is **never killed during a recording**. The whisper subprocess is killed and respawned on wedge. Recording (WAV, live.md, events, capture pipeline) is unaffected.

## 4. The single-instance invariant (G4)

Two enforcement layers:

**Layer 1 — lifecycle ownership in mac app.** The mac app gates engine startup. On Start Recording: mac app calls the existing `RefinementJobQueue.pauseForRecording()` (`RefinementJobQueue.swift:344-350`), which signals the in-flight refinement job; the refinement subprocess finishes its current region (graceful — preserves work) or is killed if it overruns a timeout. **Only after refinement-whisper has exited** does the mac app spawn engine. Engine then spawns engine-whisper. On Stop Recording: mac app SIGTERMs engine (engine kills engine-whisper as its child), then resumes the refinement queue, which respawns refinement-whisper.

**Layer 2 — structural lock at the binary.** `pulsartrace-whisper` at startup calls `flock(LOCK_EX | LOCK_NB)` on `~/Library/Application Support/PulsarTrace/whisper.lock`. On acquisition failure: exit with code `75` and a stderr message. Parents treat exit-75 as "another instance is alive — surface a user-visible error, do not loop-respawn." The lock releases automatically on process death (including SIGKILL), so it cannot get stuck.

Layer 1 makes two-instance a non-event in normal operation. Layer 2 makes it structurally impossible regardless of lifecycle bugs or races.

## 5. IPC

**Transport.** Unix domain socket at `~/Library/Application Support/PulsarTrace/sockets/whisper-<pid>.sock`. Length-prefixed framing (4-byte big-endian length + JSON payload). Matches the framing pattern used by `pulsartrace-capture` so we have one mental model.

**Request types:**

- `Init { model_path, gpu: bool }` — sent once after connect, before any decode. Subprocess loads the model and replies.
- `Decode { request_id, samples: [Float32 LE], options: WhisperOptions, language_hint?: String }` — one window or one refinement region.
- `Shutdown {}` — graceful exit on parent's request. Optional — SIGTERM works too.

**Response types:**

- `Ready { model_load_ms }` — ack to `Init`.
- `Decoded { request_id, segments: [Segment], language: String, no_speech_prob: Float }` where `Segment = { text, start_ms, end_ms, tokens: [{ id, prob, start_ms, end_ms }] }`. The token-level detail is what the existing `WhisperTranscriber.transcribeWindow` returns; refinement needs less but the same shape works for both.
- `Error { request_id?, kind: String, message: String }` — failures (model load failure, decode error, etc.).

**Why JSON, not protobuf.** Engineering simplicity. Payload is dominated by the 8s × 16kHz × 4-byte samples (~500KB), so JSON-vs-binary for the rest is noise. The samples field can be base64'd in JSON (~700KB) or we can use a binary-after-JSON framing where the JSON header declares a `samples_byte_length` and the bytes follow. Decide at implementation time; both are acceptable. **Start with base64'd JSON for simplicity; measure and switch if it costs more than 1ms/window.**

## 6. Watchdog

The existing `DecodeWatchdog` (in-engine, per-decode) is **replaced** by a parent-side process watchdog.

**Engine-side (live):** when a `Decode` is sent, start a deadline timer (10s, same as today's `DecodeWatchdog.deadline`). If no `Decoded` response by deadline: SIGKILL the whisper subprocess, spawn a new one, re-send `Init`, resume new Decodes. The wedged Decode's request is **discarded** — we have no way to know if the subprocess produced output before we killed it, and it doesn't matter (the next window will catch up via LocalAgreement-2).

**Mac-app-side (refinement):** same pattern, longer deadline (refinement regions can be longer than live windows; tune by measurement). Existing `ResumableRefiner` checkpoint logic means a killed region just resumes from the previous checkpoint.

**Throttled escalation log.** While waiting past the deadline (i.e. between SIGKILL decision and respawn ready), log on exponential backoff: 5s, 10s, 20s, 40s, 80s, 160s, 320s, then capped at 600s. This replaces the 50ms-spam pattern from 2026-05-26 (~3,948 lines in 3:36). The respawn itself should complete in 1-3s for `base` model load, so usually you see one or two lines at most.

**No more abort_callback.** It's removed from the params we send. Process death replaces it.

## 7. Integration shape

### Live (engine)

- New: `RemoteWindowTranscriber: WindowTranscribing`. IPC client. Drop-in replacement at the four construction sites: `pulsartrace-engine/main.swift:94,171,174,175`.
- `StreamingPipeline` signature widened from `WhisperTranscriber` to `any WindowTranscribing` (it already accepts the protocol through the streaming code; just need to widen the public init).
- `LiveRunner` and `StreamingTranscriber` are already protocol-based and don't change.

### Refinement (mac app)

- New: `RegionTranscribing` protocol — covers `transcribeRegion(samples, region, options) throws -> TranscriptionResult`. Sibling to `WindowTranscribing`.
- New: `RemoteRegionTranscriber: RegionTranscribing`. IPC client.
- `SharedTranscriberBox<T>` becomes generic over the protocol; `RefinementJobQueue.swift:362-364` factory returns the remote variant instead of the in-process `WhisperTranscriber`.
- `ResumableRefiner.swift:16` closure signature stays — it already takes `@Sendable ([Float], SpeechRegion, WhisperOptions) async throws -> ...` shape, just calls the remote client now.

### In-process VAD (unchanged)

- `WhisperTranscriber.detectSpeechRegions(in:vadModelURL:)` stays in-process. It loads a Silero VAD model via `whisper_vad_*` calls, runs on CPU/Metal, completes in tens of milliseconds.
- The fact that VAD uses some `whisper.cpp` C functions is irrelevant — those functions don't touch the same `whisper_context` used for transcription; metalLock contention does not cross between them (the lock is acquired only inside `transcribeWindow`/`transcribeRegion`).

### Type refactor

- Lift `WhisperTranscriber.Options` → standalone `WhisperOptions`.
- Lift `WhisperTranscriber.TranscribeError` → standalone `WhisperTranscribeError`.
- Lift `WhisperTranscriber.gpuEnabledByDefault` → standalone `defaultGPUEnabled` (or move into `WhisperOptions`).

These lifts make the types usable from `RemoteWindowTranscriber` / `RemoteRegionTranscriber` without depending on the in-process class.

## 8. Failure modes

| Scenario | Detection | Action |
|---|---|---|
| Whisper decode wedges past deadline | Parent timer expires with no response | SIGKILL, respawn, re-Init, discard wedged request |
| Subprocess crashes mid-decode | EOF on UDS read | Respawn, re-Init, discard in-flight request |
| Subprocess fails to load model | Init `Error` response, or non-zero exit before `Ready` | Surface error to UI ("model load failed"), do not loop-respawn |
| flock acquisition fails (another instance alive) | Exit code 75 | Surface error to UI, do not loop-respawn — investigate lifecycle |
| User SIGTERMs the app mid-decode | Mac app's normal shutdown | Mac app SIGTERMs engine → engine SIGTERMs its whisper child → mac app's own whisper (if any) SIGTERMs → all exit, flock releases |

## 9. What this does NOT cover

- **Memory pressure when both models would be needed simultaneously.** Today's spec keeps each subprocess to one model; if a user starts a recording while refinement is in flight, refinement is paused (not concurrent). On a 16GB Mac this is fine. If we ever want concurrent live + refine, that's a separate spec.
- **Subprocess crash patterns we haven't seen yet.** Whisper.cpp crashes (segfaults, asserts) are theoretically possible; the EOF-on-UDS path handles them, but operational visibility (was it OOM, was it a model assertion, etc.) is a follow-up.
- **VAD-side hangs.** None observed. If they ever happen, VAD moves to the subprocess too — straightforward extension.

## 10. Open implementation questions (for the plan doc, not blocking the design)

- Exact JSON schema for `Decoded.tokens` — current `WhisperTranscriber.transcribeWindow` returns a specific shape; need a 1:1 mapping.
- Refinement deadline value — measure first.
- Refinement pause behavior on Start Recording: kill-immediately vs. finish-current-region-then-exit. Current `pauseGate` does the latter; keep it for less wasted work.
- Whether `pulsartrace-whisper` is a CLI binary in the same SPM package (probably yes) or a separate target with its own Package.swift section.
- Where the engine-side IPC client lives — `PulsarTraceEngine` library (so it can be tested) vs. `pulsartrace-engine` CLI.

## 11. Acceptance criteria

- A test that deliberately wedges a decode (using an injectable mock subprocess or a `pulsartrace-whisper` test mode that hangs on a sentinel input) shows the parent SIGKILL + respawn + resume happens within `decodeDeadline + spawn-budget` (target: under 5 seconds end-to-end for live).
- Recording continues uninterrupted across the wedge — WAV size matches realtime, no gaps in the audio file.
- live.md gets a one-line note indicating live transcription restarted (similar to today's `_(recording paused)_` but with a distinct text — the existing `noteDropEdges` queue-drop note becomes "live transcription stalled — recording continues" or similar; phrasing TBD).
- The flock invariant: a test launching two `pulsartrace-whisper` processes confirms the second exits with code 75.
- No regression in refinement-while-recording behavior — pauseForRecording continues to work, refinement-whisper exits before engine-whisper spawns.
