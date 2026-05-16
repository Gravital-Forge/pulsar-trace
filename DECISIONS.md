# PulsarTrace — Plan Adjustments & Architectural Decisions

This document records deviations from `PRD.md` made during autonomous implementation,
with rationale. The PRD remains the source of truth for intent; this records the *how*.

## D1 — Run scope: v0.1 (Epics 1–5) + Epic 6 only
**Decision:** This implementation run targets Epics 1–5 (the ship-able offline CLI) plus
Epic 6 (streaming). Epics 7–10 (real device capture, menubar UI, CLI polish, distribution)
are not attempted.
**Why:** Host is an AWS EC2 Mac with no audio devices, no interactive UI session, and no
signing certificates. Epics 7–10 cannot be *verified* here; shipping unverified code for
them would violate the project's test-discipline invariant ("if you can't write the test,
the code isn't done"). Confirmed with the user.

## D2 — Pure SwiftPM for v0.1; no Xcode project / `.app`
**Decision:** v0.1 + Epic 6 build as a SwiftPM package (`Package.swift`). No `.xcodeproj`,
no `PulsarTrace.app` bundle, no SwiftUI app target yet.
**Why:** PRD §15 Epic 1 calls for a "SwiftUI app target (skeleton only)", but the menubar
app is Epic 8 (v1.0, out of scope per D1). A SwiftPM package fully supports the engine,
CLI, and three test targets, and is what `swift test --filter` operates on. The app target
is deferred to Epic 8 when it is actually built and testable.

## D3 — Development Python via Homebrew `python3.12` venv, not `python-build-standalone`
**Decision:** The Python diarization layer runs in a venv created from Homebrew's
`python3.12` (3.12.13), pinned via `requirements.lock`. `python-build-standalone` bundling
is deferred to Epic 10 (app packaging, out of scope).
**Why:** `python-build-standalone` only matters for shipping a self-contained `.app`.
For building and testing the pipeline a pinned venv is equivalent and faster to iterate.
The Swift↔Python IPC boundary is identical either way, so Epic 10 can swap the runtime
without engine changes.

## D4 — Test models: `base`; production default unchanged
**Decision:** The automated test suite uses whisper `base` (and small pyannote configs
where applicable). `large-v3` remains the documented production refinement default.
**Why:** `large-v3` is ~3GB and slow per-run; using it in snapshot tests makes the suite
too slow for the LLM dev loop the PRD's §12 prescribes and increases flake surface. Model
choice is a config knob (`--model`), so tests exercise the same code paths with `base`.

## D5 — `app_started`/`app_stopped` payload field `version` → `app_version`
**Decision:** The `app_started` / `app_stopped` events serialize their application-version
field as `app_version`, not `version`. PRD §8.13 lists the payload as `{version,
macos_version}`.
**Why:** The events-log common envelope (R80) already owns a top-level `version` field —
the per-type schema version (integer). The events log writes one flat JSON object per
line (envelope + payload merged), so a payload field also named `version` would collide
with and overwrite the envelope's. Renaming the payload field to `app_version` keeps both
values present and unambiguous. This is an additive naming choice within the same epic
that introduces the events log, so no `version` bump is needed. Documented in
`docs/events-schema.md`.

## D6 — Audio fixtures at `Tests/Fixtures/audio/`, resolved by path
**Decision:** Audio fixtures live at `Tests/Fixtures/audio/` (capitalized). `PipelineTests`
resolves them via a path computed from `#filePath`, not as SwiftPM bundle resources.
**Why:** Two parts. (1) The PRD §12 writes the fixture path as `tests/fixtures/audio/`
(lowercase). SwiftPM *requires* the test directory to be `Tests/` (capital T); on a
case-insensitive macOS filesystem `tests/` and `Tests/` are the same directory, but on a
case-sensitive filesystem they would be two — a latent cross-platform bug. Using the
single canonical capitalized `Tests/Fixtures/` removes the collision. (2) Declaring the
fixtures as a SwiftPM `.copy` resource would require them to sit inside a specific test
target's directory and would duplicate ~3.9 MB. Resolving by path keeps one committed
copy. Tests run from a normal `swift test`; only the path case and the resource-bundling
mechanism differ from the PRD's wording.

## D7 — whisper.cpp vendored + built from source, pinned by commit; linked as a SwiftPM systemLibrary
**Decision:** Transcription uses whisper.cpp's C API via FFI from Swift (not
pywhispercpp, not a `whisper-cli` subprocess). whisper.cpp is **vendored**:
`scripts/build-whisper.sh` clones `https://github.com/ggml-org/whisper.cpp.git`
pinned to **v1.8.4 — commit `9386f239401074690479731c1e41683fbbeac557`** and
builds it with cmake + Metal (`-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON`,
shared libs, deployment target 14.0, arm64). The build installs headers + dylibs
into `vendor/whisper-install/`. `Package.swift` declares a `CWhisper`
`systemLibrary` target (a modulemap + shim header) and `PulsarTraceEngine`
reaches the built library through absolute `-I`/`-L`/`-rpath` flags computed
from the package directory.
**Why:** The skill forbids pywhispercpp (embedded Python is reserved for
pyannote/diart) and per-chunk `whisper-cli` subprocesses (the model must be
resident). A vendored, commit-pinned source build with Metal embedded gives a
reproducible, hardware-accelerated, single-process resident model. The checkout
and install tree are `.gitignore`d (`vendor/`); the pinned commit + build script
make them reproducible without bloating the repo. SwiftPM cannot run the build
script itself, so the `-I/-L/-rpath` flags are `unsafeFlags` — acceptable
because the package is not consumed as a dependency by anything else.

## D8 — whisper.cpp Metal backend is single-context per process; serialized by a lock
**Decision:** `WhisperTranscriber` guards `whisper_context` creation/free and the
entire `whisper_full`+result-read region with a process-wide `NSLock`. The
offline transcription test suite is additionally marked `.serialized`.
**Why:** whisper.cpp's Metal backend keeps a per-device residency set that
asserts (`GGML_ASSERT(rsets->data count == 0)`) when contexts are created/freed
concurrently, and two contexts whose GPU compute overlaps corrupt each other's
results (observed as a garbage detected language like "af" with empty
segments). Epic 2's real usage is one source = one transcriber, so serialization
costs nothing on the offline path; it makes the single-context invariant
enforced rather than incidental. If Epic 4/6 ever need true parallel
transcription, that needs a separate design (e.g. multiple processes), not
shared Metal contexts.

## D9 — Diarization runs pyannote 4.x as a one-shot Python subprocess; HF token via env/.env in dev
**Decision:** Offline diarization (Epic 3) loads
`pyannote/speaker-diarization-community-1` via `pyannote.audio==4.0.4` in the
captive Python layer (`python/pulsartrace-ai/pulsartrace_ai/diarize.py`). The
Swift `Diarizer` invokes it as a **one-shot subprocess** per refine — WAV path
in, one JSON object on stdout (speaker spans + per-speaker embeddings + the
pyannote version string), stderr piped into the operational log tagged
`[python]` (R60). `requirements.lock` pins the full transitive closure as
resolved on the build host (torch 2.12.0, torchaudio 2.11.0, numpy 2.4.5,
scipy 1.17.1, pyannote.audio 4.0.4, …). The community-1 model is **gated**;
the Hugging Face token is read from the `HF_TOKEN` environment variable, and
in development a `.env` at the repo root supplies it (the Python test
`conftest.py` and the Swift `DiarizationE2ETests` load `.env` themselves).
**Why:** community-1 is the current best open-source diarization model and the
PRD standardises on it. A one-shot subprocess is the right shape for the
offline epic — no long-lived process, a clean failure boundary, stderr that
maps straight onto R60. The long-lived live `diart` runtime is deliberately
**not** built here; it is an Epic 6 concern with a different (streaming) IPC
shape, and `diart` drags in a divergent torch/onnx pin set, so it is kept out
of `requirements.lock` until then. `return_embeddings` is **not** passed to the
pipeline: the community-1 `DiarizeOutput` already exposes `speaker_embeddings`
(pyannote's own 256-d embedding model, R29) by default, and passing the kwarg
only triggers a "ignoring unexpected keyword" warning. The token-in-env/.env
arrangement is a development convenience; production (Epic 10) moves the token
to the macOS Keychain and exports it into the subprocess environment the same
way — the `diarize.py` module only ever sees an env var, so that swap needs no
code change here.

## D10 — pyannote model cached under PulsarTrace's own cache dir via HF_HOME
**Decision:** The pyannote model and its Hugging Face hub metadata are cached
under `~/Library/Caches/PulsarTrace/huggingface/` (the diarization layer sets
`HF_HOME` to that path before any `huggingface_hub` import resolves it) rather
than the shared `~/.cache/huggingface/`.
**Why:** Consistency with the whisper model cache
(`~/Library/Caches/PulsarTrace/models/`, ModelStore) — all PulsarTrace model
data lives under one `~/Library/Caches/PulsarTrace/` root, so uninstalling the
app reclaims it and a system-wide HF cache wipe cannot silently evict the
gated community-1 download (which would otherwise force the user back through
the token/terms flow). The first-launch download of this gated model from
Hugging Face is the permitted model-download network call (PRD §17 hard
invariant 1), not telemetry.

## D11 — Diarization JSON contract carries a `schema` integer; transcript⨉spans merge by dominant overlap
**Decision:** The Swift↔Python diarization JSON has a top-level integer
`schema` field (currently `1`); the Swift `DiarizationDecoder` rejects an
unrecognised schema rather than mis-decoding. The transcript ⨉ diarization
merge (`DiarizationMerge`) attributes each whisper utterance to the speaker
whose spans overlap it **most** ("dominant overlap"); when a *second* speaker
covers ≥ 30% of the utterance's duration, both are co-attributed as
`Speaker_0+Speaker_1`. An utterance overlapping no span keeps `Speaker_?`.
**Why:** A `schema` field lets the JSON contract evolve without a silent
mis-parse — same discipline as the events-log per-type `version`. Dominant
overlap is robust to the inevitable slack between whisper segment boundaries
and pyannote turn boundaries; the 30% co-attribution threshold surfaces
genuine talked-over speech (Epic 3's overlap edge case — "both attributions
appear") while keeping a brief cross-talk syllable from cluttering every line.
The pyannote model-version string is carried through `DiarizationResult` so
Epic 5's speaker library can refuse to match centroids across a pyannote model
upgrade (Open Question #3).

## D12 — pyannote 4.0.4's default-on OpenTelemetry is force-disabled
**Decision:** `pulsartrace_ai/diarize.py` sets `PYANNOTE_METRICS_ENABLED=false`
at module scope **before any pyannote import**, and after import also calls
`pyannote.audio.telemetry.metrics.set_telemetry_metrics(False)`. The Swift
`Diarizer` additionally injects `PYANNOTE_METRICS_ENABLED=false` into the
subprocess environment it spawns (defence in depth). The `model_revision`
field (D11 / P5) — the model checkpoint's Hugging Face commit SHA — is added
to the diarization JSON contract as a new field alongside the existing
`model_version` (the pyannote.audio *library* version, now a secondary
identity field); this is an additive non-breaking change so `schema` stays 1.
The Swift decoder reads `model_revision` as an optional field. The committed
`Tests/Fixtures/diarization/*.json` were regenerated to include it.
**Why:** pyannote.audio 4.0.4's `pyannote/audio/telemetry/metrics.py` builds an
OpenTelemetry `OTLPMetricExporter` + `PeriodicExportingMetricReader` (a
background daemon thread) at import time and `track_pipeline_apply()` would
POST pipeline name / version / a per-process session UUID / speaker counts to
`https://otel.pyannote.ai/v1/metrics` on every pipeline call. Hard Invariant #1
("No telemetry, ever") forbids this. The recording side is gated on
`is_metrics_enabled()`, which reads `PYANNOTE_METRICS_ENABLED`; setting that to
`false` before import means no metric is ever recorded, so the periodic
exporter has nothing to send and never opens a connection. The explicit
`set_telemetry_metrics(False)` call and the Swift-side env var are belt-and-
braces so no pyannote refactor or stray import order can re-enable it.
Verified: with the fix in place a real diarization runs with
`is_metrics_enabled()` returning `False` and no `Otel*`/exporter network
activity. `model_revision` is recorded because the pyannote.audio *library*
version is not a reliable proxy for *checkpoint* identity — the same library
can load different checkpoints — and Epic 5 must key centroid compatibility on
the actual checkpoint.
