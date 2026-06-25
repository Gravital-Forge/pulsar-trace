> Read [`00-overview.md`](00-overview.md) first; execute tasks in order.

# Task 18: Documentation + decision log

**Files:**
- Modify: `project-docs/DECISIONS.md` (append D39)
- Modify: `docs/release-smoke-test.md` (append the ANE acceptance checklist)
- Modify: `docs/events-schema.md` (`model_downloaded` digest note)
- Modify: `CLAUDE.md` (narrow-filter list)

- [ ] **Step 1: Append D39 to DECISIONS.md**

Read the file's tail first (match the existing entry style), then append:

```markdown
## D39 — Transcription moves to the Apple Neural Engine; whisper.cpp is removed

**Decision:** The live pass runs **Parakeet TDT 0.6B v3** on the ANE via
FluidAudio 0.15.2 (in-process, behind `WindowTranscribing`; one resident
`ParakeetEngine` shared by both streams). It is the **only** live backend —
there is no live model knob anywhere (no engine `--model`, no settings
entry; `recording_started.model_live` is fixed to `parakeet-v3`). The
refine pass runs **WhisperKit** (argmax-oss-swift 1.0.0) on the ANE, with
exactly two models: `large-v3-turbo`
(`openai_whisper-large-v3-v20240930_626MB`, the default) and
`large-v3-whisperkit` (`openai_whisper-large-v3_947MB`) — the accuracy
fallback if turbo hallucinates on real audio; switching is a Settings
change, not code. whisper.cpp is **gone**: CWhisper, the vendored build,
the `pulsartrace-whisper` subprocess, WhisperIPC, `WhisperTranscriber`,
`ModelCatalog`/`ModelStore`, and the `base`/`large-v3` ggml knobs. The
revert path, should ANE dogfooding disappoint, is `git revert` of the
cutover branch.

**Language selection** reuses the existing "Restrict to languages"
selector across both passes, plus a new explicit override:
- live: exactly one selected code becomes FluidAudio's script-aware
  `language:` hint (stops wrong-script glitches, e.g. Cyrillic on Polish
  audio); zero or several → auto (`ParakeetEngine.languageHint`).
- refine, per region decode (`WhisperKitLanguagePolicy`): explicit
  `refine --language CODE` pins outright; else one selected code pins;
  else several → WhisperKit language detection on the region slice, pinned
  to the best code **within** the selection; else auto.

**Why:** whisper.cpp's Metal decode pinned the GPU: live transcription
degraded Google Meet + screen-share fluency, and the large-v3 refine of a
1 h recording ran at ~1× real time while monopolising the GPU. The ANE is
idle during meetings; Parakeet v3 beats whisper base on Polish by ~4×
FLEURS WER (7.3% vs 30.8%); turbo is ~2–5× faster than large-v3 at
near-identical accuracy. CC-BY-4.0 (Parakeet) / Apache-2.0 (FluidAudio) /
MIT (WhisperKit, Whisper weights) all permit commercial use.

**Mechanics this changes:** refine wedge recovery is WhisperKit's
per-token callback deadline (return `false` → decode stops) instead of
SIGKILLing a subprocess; the queue's pause-release hook drops the
WhisperKit actor and ARC frees the CoreML models. The live Parakeet decode
is bounded by a 30 s semaphore deadline per window (skipped window, the
post-pass recovers). Speech regions come from FluidAudio's Silero-CoreML
VAD with the same 800 ms coalescing (`SpeechRegion.coalesced`); the D31
hallucination double-gate is ported onto WhisperKit's per-segment
`noSpeechProb`/`avgLogprob`. CoreML model bundles are SDK-managed
directories under `~/Library/Caches/PulsarTrace/models/`
(`AppPaths.modelsCacheDirectory`; D10 root preserved — the FluidAudio
silero-vad bundle uses the SDK's own default directory) with **no pinned
SHA-256**: `model_downloaded` carries a computed `DirectoryDigest`
(deterministic tree hash) instead, because upstream CoreML repos revise
bundles and a pin would turn every upstream fix into a hard failure.
`RefinementJob.modelSHA256` and `metadata.json`'s hash field record `""`
for these models; the `whisper_model` metadata field name is frozen
public schema and keeps its name. The shared option/error types are now
`TranscriptionOptions`/`TranscriptionError` (whisper.cpp's `threadCount`/
`temperature`/`vadModelURL` knobs deleted); `AbortToken` is gone — it
existed for whisper's `abort_callback`, and CoreML decodes are bounded by
the deadlines above.

**Supersedes / reshapes earlier decisions:** D7 (vendored whisper build),
D8 (Metal single-context discipline), D14's whisper-gate portion, D15
(CPU-backend tests), D36 (per-job transcriber to avoid Metal re-init —
the one-resident-model *shape* survives, the Metal rationale is moot),
and D38's whisper-subprocess recovery mechanics (the drain/worker
architecture itself survives unchanged). D24/D29's model knobs are
reshaped: the live knob is removed entirely; the refine knob is the
WhisperKit catalog (`record --refine-model`, `refine --model`, Settings).
D25 (temperature-fallback decode posture) and D26 (VAD region-segmented
decode) are re-expressed via WhisperKit's fallback ladder and FluidVAD
regions — the contracts hold, the mechanisms moved. D4's pinned-model
snapshot-test policy is superseded by fixture-keyword assertions (decoder
wording drift no longer breaks tests; the retired snapshots live in git
history).

**Stale dev-machine leftovers** (safe to delete manually, no migration
code): `~/Library/Caches/PulsarTrace/models/ggml-*.bin` and the repo's
`vendor/` build tree.
```

- [ ] **Step 2: Append the acceptance checklist to docs/release-smoke-test.md**

Read the file, match its checklist style, and append:

```markdown
## ANE pipeline (D39)

- [ ] **GPU stays free during live + Meet.** Start a Google Meet call with
  screen-share, start a recording, then run
  `sudo powermetrics --samplers gpu_power,ane_power -i 1000 -n 30`.
  Expect: ANE power clearly active during speech; GPU residency/power stays
  near the no-recording baseline (windowed live diarization adds a small
  periodic GPU blip — that is pyannote/MPS, deferred in D39). Meet video and
  screen-share stay fluent. (The old pipeline showed ~90% GPU here.)
- [ ] **Refine beats the old baseline and leaves the GPU free.** Refine
  a long (ideally ~1 h) recording with `large-v3-turbo` while watching
  `sudo asitop`: wall-clock clearly under the audio duration (the old
  GPU large-v3 ran at ~1× real time — that is the baseline to beat), ANE
  busy, GPU near-idle, and foreground work (browser/IDE) stays responsive.
- [ ] **Polish + English end-to-end.** One short Polish recording and one
  English recording: live.md text is in the right language and readable;
  final.md (auto-detect) is correct in both; `metadata.json.language`
  matches.
- [ ] **Language pre-selection.** (a) Settings ▸ "Restrict to languages" =
  Polish only, relaunch, record a short Polish clip: live.md shows no
  wrong-script (Cyrillic) glitches; the queued refine pins `pl`
  (`metadata.json.language == "pl"`). (b) Re-refine the same folder with
  `pulsartrace refine <folder> --language pl`: same result via the
  explicit flag. (c) Restrict to English + Polish, re-refine: the
  detect-among path picks the right one per recording.
- [ ] **First-use downloads emit events.** On a clean
  `~/Library/Caches/PulsarTrace/models/`, the first live + refine runs emit
  `model_downloaded` events for `parakeet-v3` and `large-v3-turbo` with
  non-empty digest `sha256` fields (`pulsartrace events tail`).
```

- [ ] **Step 3: Note the digest semantics in docs/events-schema.md**

Find the `model_downloaded` section and add one sentence to the `sha256` field description: "For the CoreML model bundles (`parakeet-v3`, `large-v3-turbo`, `large-v3-whisperkit`) this is a computed directory digest — deterministic SHA-256 over relative paths + per-file hashes (see D39) — not a pinned hash, and `size_bytes` is the bundle's total size." Also scan that file for any `base`/`large-v3` ggml example values in `model_downloaded`/`recording_started` samples and update them to the D39 names (`model_live` examples become `parakeet-v3`). Additive doc change; the event schema `version` is unchanged — same fields, refined semantics.

- [ ] **Step 4: Update CLAUDE.md's narrow-filter list**

In the repo `CLAUDE.md`, in the "verify with the narrow filters instead" list:
1. Delete the line ``- `swift test --filter Transcription` `` (the suite was deleted in task 16).
2. Add three lines (keep the list's one-line-description style):

```markdown
- `swift test --filter Parakeet` — live ANE backend (one-time ~0.5 GB model download)
- `swift test --filter WhisperKitRefine` — refine ANE backend (one-time ~626 MB download)
- `swift test --filter FluidVAD` — Silero-CoreML region detection
```

3. In the known-flaky paragraph above it, the suite list ("`Pipeline IPC integration`, `Capture IPC integration`, `RecordOrchestrator (record, R47)`, and `LiveRunner resilience`") still names existing suites — IPCTwoDaemonTests survived task 16 — so it stands; only update its mechanism sentence if it mentions whisper subprocesses (it speaks of fds/sockets/subprocess slots generically — leave as is). The `--filter IPC` line's description ("IPC suites in isolation") is still accurate — leave it.

- [ ] **Step 5: Commit**

```bash
git add project-docs/DECISIONS.md docs/release-smoke-test.md docs/events-schema.md CLAUDE.md
git commit -m "docs: D39 ANE transcription pipeline — decision log, smoke checklist, event semantics, test filters"
```
