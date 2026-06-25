# PT-P5 · Apple Neural Engine Migration — Decision Log

The reasoning behind moving transcription and diarization onto the Apple Neural Engine, recorded as
each choice was taken. Decisions PT-P5-D5–PT-P5-D8 cover the live-diarization reliability
investigation that followed the diarization cutover; PT-P5-D2–PT-P5-D4 and PT-P5-D7 carry detail
that previously lived only in branch commit messages, now captured here. Append-only; frozen at
project close.

## Decisions

### PT-P5-D1 · Transcription moves to the Apple Neural Engine; whisper.cpp is removed

*2026-06-12*

**Decision:** The live pass runs Parakeet TDT 0.6B v3 on the ANE via FluidAudio 0.15.2 (in-process,
behind `WindowTranscribing`; one resident `ParakeetEngine` shared by both streams) — the only live
backend, with no live-model knob anywhere (`recording_started.model_live` is fixed to
`parakeet-v3`). The refine pass runs WhisperKit (argmax-oss-swift 1.0.0) on the ANE over exactly two
models: `large-v3-turbo` (the default) and `large-v3` (the accuracy fallback if turbo hallucinates),
switched in Settings, not code. whisper.cpp is gone: `CWhisper`, the vendored Metal build, the
`pulsartrace-whisper` subprocess, `WhisperIPC`, `WhisperTranscriber`, and
`ModelCatalog`/`ModelStore`. Speech regions come from FluidAudio's Silero-CoreML VAD with the same
800 ms coalescing, and the PT-P2-D13 hallucination double-gate is ported onto WhisperKit's
per-segment `noSpeechProb`/`avgLogprob`. Language selection reuses the existing "Restrict to
languages" selector across both passes, plus an explicit `refine --language` override.

**Because:** whisper.cpp's Metal decode pinned the GPU — live transcription degraded Meet +
screen-share fluency, and a `large-v3` refine ran at ~1× real time while monopolising the GPU. The
ANE is idle during meetings; Parakeet v3 beats whisper `base` on Polish by ~4× FLEURS WER (7.3% vs
30.8%) and turbo is ~2–5× faster than `large-v3` at near-identical accuracy. CC-BY-4.0 (Parakeet),
Apache-2.0 (FluidAudio), and MIT (WhisperKit, Whisper weights) all permit commercial use. This
supersedes/reshapes the whisper-bound decisions PT-P1-D7 (vendored build), PT-P1-D8 (Metal
single-context discipline), PT-P1-D15 (CPU-backend tests), PT-P3-D5 (per-job transcriber to dodge
Metal re-init), and PT-P3-D7's whisper-subprocess recovery mechanics — the drain/worker live
architecture itself survives. The revert path, should ANE dogfooding disappoint, is `git revert` of
the cutover branch.

### PT-P5-D2 · Content-digest model integrity replaces the pinned content hash

*2026-06-12*

**Decision:** CoreML model bundles are SDK-managed directories under
`~/Library/Caches/PulsarTrace/models/` (the PT-P1-D10 cache root preserved) with **no pinned
SHA-256**.
`model_downloaded` carries a computed `DirectoryDigest` — a deterministic SHA-256 tree hash of the
bundle directory — as the model identity instead. `RefinementJob.modelSHA256` and `metadata.json`'s
hash field record `""` for these models; the frozen public `whisper_model` field name is unchanged.

**Because:** upstream CoreML repos revise their bundles, so a pinned hash would turn every upstream
fix into a hard download failure. A content digest still gives a stable, comparable model identity
(used downstream to refuse cross-revision speaker matches — see PT-P5-D3) without making PulsarTrace
brittle to legitimate upstream revisions. The PulsarTrace-owned HTTP-range resumable downloader and
its pinned-hash verification gate (the old `ModelStore`) are removed with whisper.cpp; the SDKs own
acquisition now.

### PT-P5-D3 · Diarization moves in-process to the ANE; the pyannote Python sidecar is removed

*2026-06-14*

**Decision:** Speaker diarization runs fully in-process on the ANE via FluidAudio 0.15.2's
`OfflineDiarizerManager` for both the offline (refine) and the live (streaming) passes. The entire
`python/` tree is deleted — no venv, no `requirements.lock`, no `pulsartrace_ai` modules — and with
it the one-shot pyannote subprocess (superseding PT-P1-D9), the long-lived windowed-pyannote
subprocess (superseding PT-P2-D1), the Swift↔Python JSON wire contract (retiring PT-P1-D11's
`schema` field), the `HF_TOKEN`/`.env` arrangement (mooting PT-P1-D10's `HF_HOME` redirect), and the
OpenTelemetry kill-switch (mooting PT-P1-D12 — there is no Python process to emit telemetry). The
models are FluidInference's CoreML conversion of `speaker-diarization-community-1` (powerset
segmentation + WeSpeaker 256-d embeddings
\+ AHC warm start + VBx/PLDA refinement), ~21 MB from the public repo
`FluidInference/speaker-diarization-coreml`. A resident `DiarizerEngine` actor owns the manager and
is loaded once per process; the live pass shares that instance, and the offline `Diarizer` keeps the
same `diarizeSystemStream(wavPath:)` entry point (PT-R17 intact — the mic is never diarized) with
cancellation now mapped onto Swift `Task` cancellation. The speaker library migrates to schema v3
(`pyannote_model_revision` → `model_revision`; a pre-v3 database is archived to `…pre-v3.bak` and
reset) and `metadata.json` to v2 (`pyannote_model` → `diarization_model { id, revision }`;
`library_version` dropped); `modelRevision` is the same `DirectoryDigest` from PT-P5-D2, carrying
the Open-Question-#3 cross-revision-refusal semantics.

**Because:** the ANE is idle during meetings, and the in-process port removes an entire embedded
runtime — venv, torch/onnx pin set, subprocess lifecycle, gated-download/token flow, telemetry
kill-switch — from the shipping app. CoreML diarization is ~21 MB versus a multi-gigabyte torch
install, runs on the Neural Engine alongside the PT-P5-D1 transcription models, and unifies the
embedding space across every pass. Carrying pyannote-space centroids forward would only produce
garbage matches against WeSpeaker embeddings, so the schema-v3 reset is mandatory, not cosmetic.
This completes the diarization deferral noted in PT-P5-D1 and supersedes the originating
specification's "pyannote stays in Python" position (now reflected in PT-R111/PT-R112). The revert
path is `git revert` of this branch.

### PT-P5-D4 · VBx warm-start `Fa = 0.2` and thresholds recalibrated for the WeSpeaker space

*2026-06-14*

**Decision:** The one deliberate deviation from FluidAudio's defaults is
`clustering.warmStartFa = 0.2` (default 0.07). The speaker-match and live-stitch thresholds are
recalibrated for the WeSpeaker geometry: `SpeakerLibrary.defaultMatchThreshold` 0.7 → 0.45 and
`LiveDiarizer.stitchThreshold` 0.55 → 0.45. Both are pinned by the `DiarizationE2E` threshold
calibration suite so a future embedding-space change fails loudly.

**Because:** at the default `Fa = 0.07` the VBx clusterer collapses two clearly-distinct voices into
one cluster on recordings shorter than ~1 minute (the prior dominates the thin per-frame evidence),
even though the embeddings separate cleanly (cross-speaker cosine ~0.35–0.38, same-speaker ~0.93).
The failure modes are asymmetric: under-separation (two people fused) has no post-hoc remedy, while
over-split (one person across two labels) is recoverable with the speaker-merge tool — so the
parameter is biased toward splitting. A sweep showed every `Fa` in 0.08–0.3 separates a two-speaker
clip and none over-splits a 2-minute single-voice concat; `Fa = 0.2` sits well clear of the
0.07/0.08 cliff. pyannote's 256-d space and WeSpeaker's 256-d space are different geometries, so the
old cosine thresholds do not transfer; 0.45 sits midway between the ~0.35 cross-speaker floor and
the ~0.93 same-speaker ceiling.

### PT-P5-D5 · Live-diarizer over-split: a live-only AHC threshold, tried and reverted

*2026-06-16*

**Decision:** The live pass does **not** get its own clustering threshold. An experiment that split
`DiarizerEngine` into a refine manager (FluidAudio default `clustering.threshold = 0.6`) and a live
manager with a raised AHC threshold (`liveClusteringThreshold = 1.05`, a Euclidean distance on
unit-normalized WeSpeaker embeddings) — to cure an observed per-window over-split where one speaker
fragments into 2–3 keys and the PT-R18 library lookup mis-names each fragment — was reverted
(`c0ddbda`). Live and refine share one resident manager at threshold 0.6.

**Because:** over-split was never the reported problem. The field failure was the opposite —
**under-split**, where short interjections collapse into whoever is already speaking — and raising
the AHC merge distance aggravates under-split. A later threshold sweep independently confirmed the
clustering threshold is a non-lever here (the speakers were already highly separable, cross-cosines
~0.28); the wedge investigation (PT-P5-D6/PT-P5-D7) found the real cause elsewhere. The experiment
never reached the integration branch, so the shipped product is unchanged.

### PT-P5-D6 · Live-diarization wedge, attempt: reclaim a wedged diar-gate slot

*2026-06-18*

**Decision:** `DiarGate` was given a slot-reclaim: a slot held past a deadline (default 2 s, ~10× a
healthy ~0.2 s window) is force-reclaimed **without awaiting** the wedged work, with a generation
token so the abandoned window's late `release()` cannot free a newer holder's slot. The intent was
that one hung `diarizeWindow` call could no longer hold the gate's single in-flight slot forever and
collapse the system stream to one speaker via the `?? "Them"` fallback.

**Because:** on a reference replay, diarization ran cleanly for ~95 s and then skipped continuously
for ~170 s — one window had wedged and never released the gate. The hang was attributed at the time
to FluidAudio's synchronous embedding `MLModel.prediction` hanging under ANE contention, deaf to
`Task` cancellation, which a `withTaskGroup` timeout cannot reclaim. This decision is **superseded
by PT-P5-D7**: reclaim proved insufficient — under a wedge storm it relaunches a new window every 5
s into a still-jammed pipeline, the un-cancellable calls accumulate (one per ~5 s), and after ~6–7
they starve Parakeet transcription, turning a diarization-only freeze into a recording-paused
regression.

### PT-P5-D7 · Live-diarization wedge: a blocking-stderr drain bug, not ANE contention; the worker is reverted, diarization stays in-process

*2026-06-19*

**Decision:** The live-diarization wedge is fixed at its real source and live diarization stays
**in-process**. A killable diarizer **worker subprocess** (the `--diarizer-worker` engine mode,
`DiarWorkerClient`/`Server`/`Connection`/`Protocol`/`Launcher`, a per-session Unix-domain socket,
and a length-prefixed wire codec — a supervisor with a per-window deadline plus SIGKILL/respawn) was
built to release a "wedged ANE call" by killing the process, but is then **reverted entirely** on
2026-06-23 (`531a1cc`, ≈ −1180 lines), along with the PT-P5-D6 gate reclaim and generation token.
Live diarization runs through `DiarizerEngineRawAdapter` over a resident `DiarizerEngine` of the
same type and WeSpeaker model the offline `Diarizer` separately loads (PT-R29 holds by construction,
not by a shared instance), and `DiarGate` returns to a plain ≤1-in-flight gate. The two fixes that
actually resolved the wedge are retained: the worker (then any subprocess) routes stdio to
`/dev/null` (`912208e`), and `RecordOrchestrator` drains subprocess pipes in chunks via a background
`readToEnd()` instead of byte-by-byte `FileHandle.bytes` on the cooperative pool (`80faa21`).

**Because:** an `lldb` + `spindump` capture of a stuck worker showed its serving thread parked ~85 s
inside `NSFileHandle.write → write` (CPU time < 1 ms; the ANE idle), emitting a `[Profiling]` line
that reported the embedding had already succeeded in ~6 ms. The wedge was never ANE contention: it
was FluidAudio's verbose profile logging blocking on a full stderr pipe that the parent drained
byte-by-byte on the cooperative pool — so under the DEBUG flood the 64 KB pipe fills and the next
`write()` blocks forever. With the cause fixed at the pipe-drain source, the worker machinery is
dead weight, and the in-process invariant "a wedged diarizer never stalls transcription or
`live.md`" still holds via the detached-task + single-slot structure. This tail (the revert and the
two fixes) lives on the `fix/live-diarizer-wedge-reclaim` branch and is the in-flight remainder of
P5 — not yet merged to the integration branch.

### PT-P5-D8 · No-coverage live utterances get a neutral `Speaker?` label

*2026-06-23*

**Decision:** When the live diarizer has no coverage for a committed system utterance,
`LiveRunner.resolveSystemLabel` returns the neutral marker `Speaker?` (`LiveRunner.noCoverageLabel`)
and skips the PT-R18 library lookup, rather than falling back to `"Them"`. The has-coverage path,
including a genuine `"Them"` span, is unchanged.

**Because:** the old no-coverage fallback `dominantKey(...) ?? "Them"` collided with a real key:
`"Them"` is exactly `LiveDiarizer.provisionalKey(index: 0)`, the first stitched speaker. A
no-coverage utterance therefore inherited the first speaker's centroid, the PT-R18 lookup resolved
it, and the line silently took the first speaker's name (field symptom: "everything became the first
speaker"). Returning a neutral `Speaker?` and skipping the lookup makes a no-coverage line accurate
— nothing was tracked — and it can never collide with `provisionalKey(0)`. This fix is part of the
in-flight wedge-reliability tail (PT-P5-D7).
