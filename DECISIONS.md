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
**Addendum (env-var overrides):** `RefineCommand` resolves the repo root (and from
it the venv interpreter) from `#filePath` — a build-machine path baked into the binary.
As a cheap robustness improvement ahead of full Epic 10 packaging, three environment
variables now take precedence when set: `PULSARTRACE_REPO_ROOT` (overrides the repo
root), `PULSARTRACE_VENV_PYTHON` (overrides the venv interpreter outright), and
`HF_TOKEN` (a real-environment token wins over the repo `.env`). The `#filePath`-derived
path remains the dev-tree fallback. This is not full packaging — it just lets the binary
run off a machine other than the build host.

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

## D13 — `refine` bare-WAV input writes outputs to a sibling folder named for the WAV stem
**Decision:** `pulsartrace refine PATH` accepts two input shapes. A
**recording folder** (already holding `audio-system.wav` + optional
`audio-mic.wav`) gets `final.md` / `metadata.json` written back into it. A
**bare WAV file** (`meeting.wav`) has no recording folder yet, so `refine`
creates one as a *sibling* of the WAV named for the WAV's stem (`meeting.wav`
→ `meeting/`) and writes the outputs there; the original WAV is left in place
and `metadata.json` records its basename in `source_basename`. A bare WAV is
treated as a single (system) stream — it is diarized and all its speakers are
`Speaker_N`; there is no separate mic stream and therefore no `You` label.
**Why:** PRD §6 fixes the storage model as "one folder per recording" holding
the audio, `final.md`, `metadata.json` (and later `live.md`). A bare-WAV input
predates that folder, so one must be created. Putting outputs in a dedicated
sibling folder (rather than next to the WAV, or inside a folder that also
absorbs the WAV) keeps the user's original audio file untouched, groups
`final.md` + `metadata.json` together, and matches the §6 model exactly. The
recording id is a deterministic slug of the folder/WAV stem, so a re-refine of
the same recording reuses its id across runs.

## D14 — Atomic write-then-rename for `final.md` / `metadata.json`; cross-suite whisper test gate
**Decision:** `final.md` and `metadata.json` are written via `AtomicFile`: the
bytes go to a sibling temp file in the destination directory and are
`replaceItemAt`-renamed into place, so a consumer (an AI agent, or an editor
with the file open) ever sees either the whole old file or the whole new file,
never a torn one (R24, Epic 4 "file replacement while editor is open" edge
case). On a re-refine (R27) the prior `final.md` is copied to `final.md.bak`
*before* the atomic replace; a pre-existing `live.md` is renamed to
`.live.md.bak`. Separately, the test suite gains a process-wide
`WhisperTestGate` actor: `@Suite(.serialized)` only serializes tests *within*
one suite, but `TranscriptionPipelineTests` and `RefinementPipelineTests` both
load whisper, and two `whisper_context`s alive at once in one process corrupt
each other's Metal residency set (DECISIONS.md D8). Every whisper-using test
body runs inside `WhisperTestGate.run { … }`, serializing them across the whole
process — mirroring the engine's real "one transcriber at a time" usage and
keeping the deterministic snapshots stable (PRD §12).
**Why:** The temp file must be on the *same volume* as the destination or the
rename silently degrades to a non-atomic copy — hence the sibling temp file,
not `NSTemporaryDirectory()`. The whisper gate was added after the new Epic 4
suite intermittently corrupted the Epic 2 transcription snapshot when the two
whisper-heavy suites ran in parallel; per-suite `.serialized` could not cover
a cross-suite race.

## D15 — Tests use whisper's CPU backend; production keeps Metal
**Decision:** `WhisperTranscriber.init` gains a `useGPU` parameter, defaulting
to `true` (production — the Metal backend, `-DGGML_METAL=ON`). The test/CI
transcription path constructs every transcriber with `useGPU: false` (whisper's
CPU backend), via the `WhisperTestTranscriber.make(modelURL:)` helper used by
`TranscriptionPipelineTests` and `RefinementPipelineTests`.
**Why:** `swift test --filter Pipeline` intermittently aborted at *process exit*
with `GGML_ASSERT([rsets->data count] == 0)` / signal 6 inside
`ggml_metal_device_free` — an upstream whisper.cpp/ggml-metal residency-set bug
triggered on this M1 host once several `whisper_context`s have been created and
freed in one process (the test suite loads whisper many times). The crash is at
teardown, after the assertions have passed, but a suite that aborts on exit is
unacceptable — PRD §12's test discipline depends on `swift test --filter
Pipeline` being reliably green. whisper's CPU backend never constructs a
ggml-metal device, so it cannot reach that assertion; `base` over the short
committed fixtures is plenty fast on CPU. Production is unaffected: `useGPU`
defaults to `true`, so the engine and the `pulsartrace` CLI still run on Metal.
This is orthogonal to D8's `metalLock` / `WhisperTestGate` serialization —
those address concurrent-context corruption *during* a run; D15 addresses the
exit-time device-free assertion.

## D16 — Epic 5 CLI rename/merge updates the library only; retroactive `final.md` rewrite is Epic 8
**Decision:** A `pulsartrace speakers rename` / `merge` in Epic 5 updates the
speaker library and emits the corresponding `speaker_renamed` / `speaker_merged`
event with an **empty** `applied_to_recordings`. It does **not** rewrite any
past `final.md` file, and emits **no** `final_md_rewritten`. The new name takes
effect on the next `pulsartrace refine` of a recording, when reconciliation
applies it.
**Why:** PRD §15 explicitly scopes the retroactive rewrite of past `final.md`
files (and the paired `final_md_rewritten` event, one per affected recording)
to **Epic 8** (the menubar editor / full management surface). Keeping Epic 5's
CLI to a library-only mutation honours Hard Invariant #8 (events paired with
their causes): because Epic 5 emits no file change, it needs no
`final_md_rewritten` to pair with. The appearances table records every
speaker↔recording link (with the recording folder basename) precisely so Epic 8
can later enumerate and rewrite those files. The `speaker_renamed` event's
`applied_to_recordings` field is in the schema from Epic 5 (empty) so Epic 8 can
populate it without a schema version bump.

## D17 — Speaker library uses the built-in `SQLite3` C module, not a SwiftPM dependency
**Decision:** `SpeakerLibrary` persists to `speakers.sqlite` through a thin
hand-rolled wrapper (`SQLiteDatabase`) over `import SQLite3` — the C SQLite
library that ships with macOS — rather than adding a SwiftPM package
(GRDB, SQLite.swift, …).
**Why:** the speaker-library schema is two small tables; the wrapper is less
code than integrating, pinning and tracking a third-party package, and it adds
no supply-chain surface or version-drift risk (consistent with the project's
minimal-dependency stance — see `Package.swift`, which carries only swift-log
and swift-snapshot-testing). `import SQLite3` is a system module always present
on the macOS SDK toolchain, so `swift build` needs no extra setup. WAL mode
(R32a), `PRAGMA integrity_check` for corruption detection, and `BEGIN IMMEDIATE`
transactions are all reached directly through the C API.

## D18 — `unmerge` reconstructs primary's pre-merge centroid arithmetically
**Decision:** `SpeakerLibrary.unmerge` restores the primary speaker's centroid
to its exact pre-merge value by *inverting* the merge's count-weighted mean,
rather than leaving the merged centroid in place (the prior best-effort
behaviour). A merge computes `merged = (primaryOld·np + other·no)/(np+no)`;
`other`'s own centroid is never recomputed by a merge (only soft-deleted) and
the appearances the merge moved are stamped `origin_speaker_id = other`, so at
unmerge time `no` is recoverable as the count of those stamped rows and
`np = primary.appearanceCount − no`. `primaryOld` is then
`(merged·(np+no) − other·no)/np` (`Centroid.unmergePrimaryCentroid`). When the
inversion cannot be exact — `np ≤ 0`, or a centroid dimension mismatch — the
merged centroid is left in place as a documented fallback.
**Why:** the review (S4) required `unmerge` to be a true undo, not a partial
one. The brief offered two options: reconstruct arithmetically, or snapshot the
pre-merge centroid into the merge event / a new column. Arithmetic
reconstruction was chosen because all the inputs are already durably present
(`merged` and `other` are stored centroids; `np`/`no` are derivable from the
preserved `origin_speaker_id` stamps and the appearance count), so it needs **no
schema change and no events-log schema bump** — consistent with D16's stance of
keeping Epic 5 additive. The one inexactness is the `UPDATE OR IGNORE` collision
case in `merge` (a recording both speakers already appeared in): there the moved
row count can undercount `other`'s true pre-merge appearances, so the
reconstruction is approximate. That collision is already documented as rare and
best-effort in `merge`'s own comment, and the fallback path covers the
non-invertible case, so no separate snapshot column was added.

## D19 — Live diarization uses windowed-pyannote, not `diart` (Open Question #1)

**Decision:** Epic 6's live (streaming) speaker diarization runs the existing
pyannote 4.x pipeline on a **sliding window of recent system audio** —
"windowed-pyannote" — driven by a long-lived captive subprocess
(`pulsartrace_ai.live_diarize`). It does **not** use `diart`, the streaming
diarization toolkit the PRD recommended.

**Why:** `diart` cannot be installed into the project's pinned venv without
breaking the working Epic 3 offline diarization. `pip install diart` resolves
`pyannote.audio` **down from the pinned 4.0.4 to 3.4.0** (verified with
`pip install --dry-run diart`: it would install `pyannote.audio-3.4.0`,
`numpy-1.26.4`, `speechbrain`, …). Epic 3 standardised on
`pyannote/speaker-diarization-community-1`, which is a pyannote 4.x model; the
downgrade would break offline diarization outright and break the
cross-comparability of speaker-library centroids (R29 — embeddings must come
from one pyannote pipeline). PRD §16's Open Question explicitly lists
windowed-pyannote as the viable alternative ("more accurate but adds ~30s
lag"), so that is what PulsarTrace ships. The added lag is acceptable: live
diarization is best-effort and provisional (R16), the post-pass is the source
of truth, and the windowing here uses a ~10 s window stepped every ~5 s — far
short of 30 s.

**Design of the windowed approach:** the Swift `LiveDiarizer` launches the
Python `live_diarize` module **once** (the ~10–30 s model load is paid a single
time, not per chunk) and streams it windows over a newline-framed JSON protocol
on stdin/stdout — `{window_wav, window_start}` request → `{speakers, spans,
embeddings}` response. pyannote's per-window labels are not stable across
windows (windowed online diarization spawns labels freely), so `LiveDiarizer`
**stitches** them into stable per-recording provisional keys (`Them`, `Them #2`,
…) by matching each window-speaker's embedding against a running set of
live-speaker centroids by cosine similarity. The post-pass corrects everything.

The PRD's risk register flags "choosing diart vs windowed-pyannote" as an
ask-first item; the Epic 6 brief delegated this decision to the implementer and
required it be documented here — this entry is that documentation. The choice
was forced by a hard dependency conflict, not a preference: shipping `diart`
was not possible without regressing a committed epic.

## D20 — Streaming transcription: anchored-window whisper + LocalAgreement-2

**Decision:** The live pass transcribes with a sliding **anchored** whisper
window plus a **LocalAgreement-2** committer, rather than whisper.cpp's bundled
`stream` example or a free-sliding window.

**Why LocalAgreement-2:** `live.md` is strictly append-only (invariant #4 /
R36) — a word, once written, can never be revised. But the tail of any single
whisper hypothesis over a short window is unstable (a word near the window edge
often changes once more audio arrives). LocalAgreement-2 (Liu et al. 2020, the
algorithm `whisper_streaming` uses) commits a word only once **two consecutive
hypotheses agree on it** — the longest common prefix of the two. Unstable tail
words are simply held back, never emitted. This is what makes append-only
`live.md` correct: every committed word survived two independent decodes, so it
never has to be taken back.

**Why an *anchored* window, not a free-sliding one:** an early implementation
slid the window's *start* forward with real time. That fails: two consecutive
windows then cover different audio spans and share only a *middle*, never a
*prefix* — and LocalAgreement-2 compares *prefixes*, so almost nothing ever
committed (the smoke test produced one line for a 24 s recording). The fix is
the `whisper_streaming` design: the window is **anchored at the last committed
audio position** and only its end grows. Consecutive windows then share a
prefix; the committer's longest-common-prefix is meaningful; the sample buffer
is trimmed at the anchor after each commit so memory stays bounded. The
committer's "skip already-committed words" step is **key-based** (match the
committed tail against the new hypothesis prefix by normalized word key), not
time-based, so it is robust to the timestamp jitter two windows give the same
words.

**Backpressure:** whisper must decode a window before the next is due. If it
falls behind real time by more than two windows, the anchor is skipped forward
to catch up (coarser commits, bounded memory and lag) and the overrun is
logged — it never blocks the source or grows the buffer without limit.

**Lag (R10):** on the Metal/GPU backend (production) the measured median live
lag on the test fixtures is ~1 s, well within R10's ≤ 5 s. The test suite must
use the CPU backend (D15), which does not keep real-time pace on the longer
fixtures; the Pipeline realtime test therefore asserts the *backpressure
invariant* (lag stays bounded, `live.md` grows monotonically) rather than the
≤ 5 s figure, and R10's ≤ 5 s is verified by the manual GPU smoke test.
