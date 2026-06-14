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
**Addendum (Epic 7):** A later run continued on a real-audio-capable host (Apple M2,
BlackHole installed, Microphone + Screen Recording TCC granted — see `PREWORK.md`), so
**Epic 7 (Real Device Capture) was implemented and verified** there, including the
opt-in device tests (`PULSARTRACE_DEVICE_TESTS=1`). Epics 8–10 remain for later runs.

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

## D21 — Pause/resume travels the capture socket as in-band `FrameProtocol` control frames

**Decision:** `pulsartrace-capture` signals a recording pause/resume (system
sleep, R7; audio-device change, R8) to the engine **in-band** on the existing
`capture.sock` stream, by extending `FrameProtocol` with **control frames**: a
length prefix that is neither the `0` end-of-stream sentinel nor a positive
multiple of 4 (a value a Float32 PCM frame can never have), whose payload is a
one-byte opcode plus opcode data. `paused` is a 1-byte frame (`length 1`);
`resumed` is a 9-byte frame (`length 9`: opcode + an 8-byte little-endian
nanosecond gap). `SocketSource` decodes them into `AudioStreamEvent.paused` /
`.resumed(gap:)`, which `LiveRunner` turns into a `live.md` gap annotation.

**Why:** the alternatives were a separate control side-channel socket, or a
tagged-frame protocol wrapping every PCM frame with a type byte. The in-band
sentinel approach is the smallest change and is consistent with how
`FrameProtocol` already signals end-of-stream (a reserved `length 0`). It is
**purely additive and backward-compatible**: a PCM frame's length is always a
positive multiple of 4, so a control length can never be mistaken for one;
`FixtureSocketServer`, `PipeSource`, `RawPCMPipeSource`, and every Epic 1–6
test write only PCM frames + the `0` sentinel, so none are affected. The
read-exactly-`length`-bytes invariant is preserved (the opcode + data are the
frame's whole payload). `capture.sock` is an internal IPC contract between
PulsarTrace's own processes — not one of the three public API surfaces
(`live.md`, `final.md`, `events/*.jsonl`) — so extending it needs no public
version bump. The `live.md` gap annotation reuses the italic-note line kind
`final.md` already uses for "no speech detected" (`docs/file-format.md`
Versioning lists an optional annotation line as a non-breaking addition).

## D22 — `pulsartrace-capture` is a thin executable over a `PulsarTraceCapture` library that depends on `PulsarTraceEngine`

**Decision:** Epic 7's capture code lives in a new SwiftPM **library** target
`PulsarTraceCapture` (the `DeviceCaptureSource` orchestrator, the AVFoundation
and ScreenCaptureKit capture engines, `AudioConverter`, `CaptureSocketServer`,
the sleep/wake monitor, the permission checker). The `pulsartrace-capture`
executable target is a thin `main.swift` over it. `PulsarTraceCapture`
**depends on `PulsarTraceEngine`** for the shared wire types (`FrameProtocol`,
`AudioFrame`/`AudioFormat`, `AudioStreamEvent`) and the events log.

**Why:** two consumers need the capture code — the `pulsartrace-capture`
executable and the `CaptureTests` target (which `@testable import`s it for the
device-gated tests) — so it cannot live inside the executable target. The open
choice was whether to also extract the shared wire types into a third
`PulsarTraceIPC` library so `PulsarTraceCapture` need not depend on the whole
engine. That was rejected: it would create a diamond
(`PulsarTraceCapture → PulsarTraceIPC ← PulsarTraceEngine`) and force every
consumer to import two modules, for no real benefit — `PulsarTraceCapture`
genuinely needs only a handful of engine types, and duplicating the wire codec
(a contract both sides must agree on byte-for-byte) is a worse risk than a
build-time dependency edge. The PRD's "the capture daemon is the only process
that needs TCC permissions" (R4) is about *runtime* TCC grants, not the
compile-time module graph: linking the engine library into the capture binary
does not give it TCC requirements — only *calling* AVFoundation/SCK does, and
only `PulsarTraceCapture` does that.

## D23 — Epic 9 (CLI Surface) implemented before Epic 8 (Menubar UI); `record` orchestration is a reusable engine-library type

**Decision:** Epic 9 was implemented **before** Epic 8, reversing the PRD §15
ordering. `pulsartrace record` orchestration lives in a `PulsarTraceEngine`
library type, `RecordOrchestrator`, which spawns both `pulsartrace-capture`
and `pulsartrace-engine` as subprocesses; the `pulsartrace` CLI also gained a
`PulsarTraceCapture` dependency so `doctor` can read TCC state and
`doctor --capture-test` can drive the real capture path.

**Why:** the PRD lists Epic 8 as an Epic 9 dependency, but only for
"settings/library code paths to reuse" — a reuse convenience, not a hard
blocker. `refine`/`speakers` already shipped (Epics 4–5); the missing surface
(`record`, `doctor`, `events tail`, `install-cli`) needs no settings store. A
flag-driven `record` is exactly the PRD's own "done" criterion
(`pulsartrace record --duration 60m --output meeting.md`). Confirmed with the
user. The dependency simply inverts: Epic 9 builds the orchestration
standalone, and Epic 8's menubar later reuses `RecordOrchestrator` (settings
become a default-provider feeding the same plan). The orchestrator spawns the
engine as a *separate process* — rather than running `StreamingPipeline`
in-process — because that reuses the fully-verified Epic 7
`pulsartrace-engine --live --system-socket … --mic-socket …` entry point
unchanged, and gives Epic 8's menubar the engine-crash isolation its edge
cases require ("engine crash mid-recording, menubar detects, offers
recovery"). The CLI stays settings-agnostic permanently: the menubar will not
shell out to `pulsartrace`; both are sibling front-ends over `PulsarTraceEngine`.

## D24 — `record --output` is the recording-folder directory; `--model` applies to both passes

**Decision:** `pulsartrace record --output PATH` interprets `PATH` as the
recording-folder *directory* (a trailing `.md` is stripped as a courtesy, so
`--output meeting.md` produces the folder `meeting/`). `record --model`
applies to **both** the live pass and the subsequent post-pass refine; the
default is `base`.

**Why:** PulsarTrace's unit of work is the recording folder (`live.md` →
`final.md`, `audio-*.wav`, `metadata.json`), not a single file — R47's
`--output meeting.md` is illustrative shorthand. Resolving it to a directory
keeps `record` consistent with `refine`, which also operates on folders.
Using one `--model` for both passes avoids a surprise: a headless `record`
defaulting the refine pass to the PRD's `large-v3` would trigger an unasked-for
~3 GB download. `base` is fast enough for the live pass and adequate for the
post-pass; a user wanting `large-v3` quality passes `--model large-v3` or runs
`pulsartrace refine` separately afterward.

## D25 — Offline refine decodes with a non-zero whisper temperature + fallback and built-in VAD; the streaming pass keeps temperature 0

**Decision:** The offline `WhisperTranscriber.transcribe(_:)` path (the
`refine` pass) now decodes at `temperature = 0.2` with `temperature_inc = 0.2`
(fallback ladder 0.2 → 0.4 → … → 1.0) and, when a Silero VAD model is
supplied, enables whisper.cpp's built-in VAD (`whisper_full_params.vad`). This
deviates from PRD R64 / §860 ("whisper temperature 0" for determinism). The
VAD model (`ggml-silero-v5.1.2.bin`, ~885 KB, from the `ggml-org/whisper-vad`
Hugging Face repo) is pinned in `ModelCatalog.sileroVAD` and fetched by
`ModelStore` exactly like the whisper models (R54c/R54d); a VAD-fetch failure
degrades gracefully to a no-VAD whole-buffer decode rather than failing the
refine. The streaming `transcribeWindow` path is **unchanged** — temperature
0, greedy, no whisper VAD.

**Why:** fed a whole recording in one `whisper_full` call, the offline path
degenerated on long stretches of pure digital silence (a paused far end, a
loopback stream with nothing playing → exact-zero samples). A silent 30-second
window sent the greedy decoder into a repetition loop, and with
`temperature_inc = 0` there was no fallback re-decode to escape it — the
degenerate tokens became the prompt for the next window, so every later window
in the call collapsed to a single garbage token and skipped ~30 s of real
speech. Observed on a real recording: the system stream's monologue reduced to
`The` / `have` / `to` fragments while the mic stream (no fully-silent window)
transcribed fine. Temperature fallback is whisper.cpp's own recovery mechanism;
VAD removes the silent windows before they can trigger the failure at all. The
streaming path never hit this — it VAD-gates short windows upstream — which is
why it keeps temperature 0: LocalAgreement-2 needs two overlapping windows to
decode their shared audio *identically*, which argmax gives and sampling does
not. Determinism (R64's intent) is preserved: whisper.cpp seeds its sampler
RNG with a fixed per-call constant (`std::mt19937(0)`), so a non-zero
temperature is still byte-reproducible run-to-run on a given build — the
mechanism shifts from "temperature 0" to "fixed-seed sampler", the guarantee
does not. Confirmed with the user.

## D26 — Offline refine transcribes each VAD speech region separately, not the whole buffer

**Decision:** The `refine` pass no longer feeds the whole stream to one
`whisper_full` call with whisper's built-in VAD enabled (D25's mechanism).
Instead, `WhisperTranscriber.detectSpeechRegions(in:vadModelURL:)` runs the
Silero VAD on its own to get the stream's speech regions, coalesces regions
closer than 800 ms (the streaming pipeline's `utteranceGap`) into turn-sized
spans, and `transcribe(_:regions:options:)` decodes each region as an
independent `whisper_full` call, shifting its segment timestamps back onto the
recording timeline. whisper's built-in VAD is **off** for each region decode.
The whole-buffer `transcribe(_:options:)` path (and its built-in-VAD support)
is kept as the fallback when no VAD model is available or region detection
fails. The streaming `transcribeWindow` path is unchanged.

**Why:** D25's built-in VAD fixed the silence-degeneration failure but
introduced an ordering bug in the merged `final.md`. whisper's built-in VAD
strips the silence and then *concatenates* the speech into one buffer before
decoding, so whisper's own segmenter no longer sees the pauses and glues a
speaker's clauses across a multi-turn stretch into one long segment stamped at
its start. The two streams are merged into `final.md` by segment start time
(`RefinementPipeline.mergeStreams`), so a long mic-stream segment that
temporally *contains* the other speaker's turns sorts ahead of all of them —
the transcript then reads as if one speaker said a whole monologue before the
other replied, even referencing things the other had not yet said. Decoding
each VAD region separately keeps a turn bounded by the pause where the speaker
stopped to listen, so the time-order merge interleaves the two streams in
causal order. Granularity sits between the over-fragmented append-only
`live.md` (per streaming window) and the old one-segment-per-monologue final:
regions within 800 ms are merged so the transcript breaks at genuine turn
pauses, not every breath. Reported by the user from a real two-party
recording; confirmed with the user.

## D27 — Epic 8 module layout: `PulsarTraceMenuBar` library + `pulsartrace-mac` executable; no `.xcodeproj`; passive global hotkey

**Decision:** Epic 8's menubar logic lives in a new SwiftPM **library** target
`PulsarTraceMenuBar` (ViewModels, state stores, the recording-status state
machine, the recordings-folder scanner, the settings store, the `live.md`
watcher). A new thin **executable** target `pulsartrace-mac` holds only the
SwiftUI `App` struct, the `MenuBarExtra` scene, and `View` structs that are
pure bindings over the library's `@Observable` types. `PulsarTraceMenuBar`
depends on `PulsarTraceEngine` and `PulsarTraceCapture`; `pulsartrace-mac`
depends on `PulsarTraceMenuBar`; a new `MenuBarTests` target `@testable
import`s the library. No `.xcodeproj` or `.app` bundle is introduced — that is
Epic 10 scope (continuing D2). `NSApp.setActivationPolicy(.accessory)` is set
in code (`PulsarTraceMacApp.init()`), not via an `Info.plist` `LSUIElement`
key, so the package stays bundle-structure-free. The configurable global
start/stop hotkey (R41) uses a **passive** `NSEvent.addGlobalMonitorForEvents`
monitor, not an active `CGEventTap`.

**Why:** This mirrors D22's `PulsarTraceCapture`/`pulsartrace-capture` split. A
library target is required because `MenuBarTests` must `@testable import` the
ViewModels — an executable target's internals are not importable. Keeping
`pulsartrace-mac` logic-free draws the boundary explicitly: anything
unit-testable belongs in `PulsarTraceMenuBar`; anything that needs an
interactive macOS session (`MenuBarExtra` rendering, the hotkey monitor, real
window presentation) stays in the executable and is covered by the manual
smoke test. The dependency edge is a simple chain (`pulsartrace-mac` →
`PulsarTraceMenuBar` → `PulsarTraceCapture` → `PulsarTraceEngine`), no diamond.
The passive hotkey monitor is chosen because an active `CGEventTap` would
require the user to grant **Accessibility** TCC — the broadest, most alarming
permission macOS offers — which is at odds with the project's
minimal-permissions, no-telemetry ethos and would bloat Epic 10's onboarding.
The accepted tradeoff: a passive monitor cannot suppress the keypress, so the
hotkey also reaches the frontmost app; users pick an uncommon combo.

## D28 — Epic 8's menubar re-refine runs `OfflineRefiner` in-process; never shells out to the `pulsartrace` CLI

**Decision:** The menubar's post-recording refine and recordings-list
re-refine (`RecordingViewModel`, `RecordingsScanner`) run the offline refine
pass **in-process** through a new `PulsarTraceEngine` type, `OfflineRefiner`.
They do **not** spawn `.build/debug/pulsartrace refine` as a subprocess. The
re-refine closures stay injectable so tests inject a stub; the production
default builds an `OfflineRefiner` from the shared `EventWriter` + `AppPaths`.

**Why:** D23 already states the rule — "the CLI stays settings-agnostic
permanently: the menubar will not shell out to `pulsartrace`; both are sibling
front-ends over `PulsarTraceEngine`." The initial Epic 8 implementation
violated it by running `Process` over the CLI binary. `OfflineRefiner`
encapsulates the whole refine orchestration `RefineCommand` previously held
inline — model fetch/verify, Silero VAD, the dev-environment `Diarizer`
wiring (venv interpreter, repo root, `.env` — D3/D9), the speaker library,
and `RefinementPipeline` — so the CLI and the menubar share one in-process
entry point with identical behaviour and identical events. A refine failure
propagates as a thrown error (the old `Process` path ignored
`terminationStatus`, silently treating a crash as success). This also removes
the `#filePath`→`.build/debug/pulsartrace` path baked into the menubar, which
would not survive Epic 10 packaging anyway.

## D29 — The menubar separates the live and refine transcription models

**Decision:** The menubar exposes **two** transcription-model settings —
`liveModelName` (live pass, default `base`) and `refineModelName` (refine
pass, default `base`) — where the CLI's `record` keeps a single `--model`
knob for both passes (D24). `MenuBarSettings` persists both keys and migrates
a pre-D29 single `modelName` value into `liveModelName` on first load.
`SettingsView` shows two pickers ("Live transcription model" / "Refinement
model"), each offering `base` and `large-v3`, with a note that `large-v3` is
higher quality and ~3 GB.

**Why:** The PRD wants a fast model for the live pass and a higher-quality
model for refinement (D4 documents `large-v3` as the production *refinement*
default). D24 deliberately kept the headless CLI to one knob to avoid a
surprise ~3 GB `large-v3` download on a non-interactive `record`. The menubar
is interactive: the model choices are visible pickers a user explicitly sets,
so the surprise-download risk D24 guarded against does not apply. Defaulting
both to `base` still keeps a first run download-free; the user opts into
`large-v3` for refinement when they want the quality.

## D30 — The menubar output folder is stored as a plain filesystem path, not a security-scoped bookmark

**Decision:** `MenuBarSettings` persists the chosen output folder as a plain
path `String` (`outputFolderPath`, with `previousFolderPaths: [String]` for
prior folders), not as a security-scoped bookmark `Data`. `outputFolderURL`
derives the URL directly with `URL(fileURLWithPath:)`. The `makeBookmark` /
`resolveBookmark` / `.withSecurityScope` machinery is removed. On load, an old
install's legacy `outputFolderBookmark` / `previousFolderBookmarks` keys are
best-effort resolved once (without security scope) into paths and then deleted;
if a legacy bookmark cannot resolve, the output folder is simply left unset.
This supersedes D27's note that the folder was bookmarked "from the start" for
a future sandboxed build.

**Why:** Security-scoped bookmarks are an **App Sandbox** mechanism, but
PulsarTrace v1 is explicitly unsandboxed (PRD §17 non-goals). For an
unsandboxed, unsigned, frequently-rebuilt dev app the bookmark resolved stale
across rebuilds and the user's folder selection was silently lost on every
relaunch — the exact dogfooding bug this fixes. A plain path has no such
fragility, and an unsandboxed process can open any path directly. If a
sandboxed build is ever needed (Epic 10), bookmarks can be reintroduced then,
behind the same `outputFolderURL` accessor.

## D31 — Offline transcription drops whisper silence-hallucinations behind a phrase + confidence double-gate

**Decision:** The offline / refine transcription path (`WhisperTranscriber`'s
whole-stream and VAD-region decodes — `collectSegments(dropHallucinations:
true)`) drops a segment when, and only when, **both** hold:
1. its text, normalized (lowercased, surrounding punctuation/whitespace
   stripped), matches a known whisper silence-hallucination phrase —
   `"thank you"`, `"thanks"`, `"thank you for watching"`, `"please
   subscribe"`, `"you"`, `"okay"`, `"bye"`, … (`HallucinationFilter.stockPhrases`);
   **and**
2. an objective per-segment signal says the underlying audio is
   silence / a low-confidence guess — whisper's `no_speech_prob ≥ 0.30`
   *or* the mean per-token log-probability `≤ -0.80`.

A phrase match **alone never drops a segment**. The streaming
`transcribeWindow` path is unchanged (`dropHallucinations` defaults to
`false`).

**Why:** Fed a near-silent stream (a paused far end, a loopback with nothing
playing), whisper confidently decodes a stock phrase — most often
`"Thank you."` — over the silence. Unlike the YouTube-only phrases
`BlankTokenFilter` already removes on text alone, `"Thank you."` / `"Okay"` /
`"you"` are also legitimate meeting utterances, so they cannot be filtered by
text. A real two-party recording surfaced this: a mic-only session got two
`Speaker_?: Thank you.` lines injected into `final.md` from the silent
system-audio stream (a hallucinated segment overlaps no diarization span, so
it takes the `Speaker_?` label). The double-gate closes the gap without ever
dropping a real utterance: a genuine `"Thank you."` spoken into a live mic
decodes with a low `no_speech_prob` (~0.05) and a healthy avg logprob (~-0.2),
so it fails gate (2) and is always kept. The thresholds are deliberately
loose-on-phrase / strict-on-confidence: whisper's own `no_speech_thold` of
0.6 already rejected the clearly-silent segments upstream, so the `0.30…0.60`
grey zone it let through, combined with a stock-phrase match, is almost
certainly a hallucination. Scoped to the offline path because the streaming
path VAD-gates short windows upstream (the silent-window failure cannot
arise) and LocalAgreement-2 must see every committed token (D20).

## D32 — Crash-safe incremental WAV for the live pass

**Decision:** The live pass writes `audio-system.wav` / `audio-mic.wav`
incrementally through a new `StreamingWAVWriter`: a 44-byte header with
placeholder sizes is written at session start, every captured frame is
appended to the open file handle, and the RIFF / `data` chunk sizes are
re-patched in place (throttled to ~1x/s) so the on-disk file is at all times
a valid WAV. The previous design — `LiveRunner` accumulating the whole
recording in two in-RAM `[Float]` buffers and calling `WAVWriter.write` once,
at the end of a clean run-loop exit — is removed.

**Why:** A dogfooding incident lost an ~18-minute recording in full. The live
engine wedged (a silently stalled capture stream — see D33), the menubar's
60s stop-grace then force-killed it, and because the WAVs had not yet been
written the post-recording `refine` failed with "recording folder contains
no audio-system.wav". Buffering the entire recording for a single end-of-run
write means any abnormal end — wedge, crash, OOM, force-kill — loses 100% of
the captured audio. Incremental writing makes a recording always
recoverable: the worst case is <=1s of un-patched tail. It also bounds the
live pass's memory, which previously grew unbounded with recording length.

## D33 — Capture-stream stall detection + auto-restart (reusing pause/resume)

**Decision:** Each capture engine (`SystemAudioCaptureEngine`,
`MicCaptureEngine`) runs a `FrameWatchdog` that fires if no audio frame is
delivered within a per-stream threshold (6s system, 4s mic). On a stall,
`DeviceCaptureSource.handleStall(stream:)` tears down and rebuilds that one
capture engine — exactly the operation `handleSleep`/`handleWake` already
perform for system sleep — with capped exponential-backoff retry
(1->2->4->8->10s) re-scheduled off the serial restart queue so a long retry
never blocks a concurrent sleep/wake. The recovery is surfaced as the
existing in-band pause/resume control frames, so the engine treats a stall
recovery identically to a sleep gap; `recording_paused`/`recording_resumed`
carry `reason: "stall_recovery"`. A second, longer engine-side watchdog
(20s, via a periodic run-loop tick) is the backstop for a daemon that dies
outright: it annotates the gap in `live.md` and keeps the run loop alive,
never ending a stream on silence — only on a real socket EOF.

**Why:** ScreenCaptureKit (and, separately, the AVFoundation mic) streams can
stop delivering audio buffers with no error and no end-of-stream — observed
in the field after ~17 minutes. Nothing detected it: the capture engines had
no inactivity timer, and the engine's run loop blocked forever on a source
that would never yield a frame or an EOF, so the menubar kept showing
"recording" on a dead session (its crash-watch only fires on process exit).
Reusing the proven sleep/wake rebuild path — rather than inventing a new
recovery mechanism or a new wire message — keeps the change small and means
the engine needs no protocol change. The two-tier design (the daemon
restarts its own stream fast; the engine tolerates a longer outage without
wedging) means a recording continues through a transient capture failure
and, combined with D32's incremental WAV, survives even a total
capture-daemon loss.

## D34 — Refinement runs through a single-worker async queue; recording no longer blocks on refine

**Decision:** Refinement work for the menubar app — auto-post-recording,
manual "Refine" from the recordings list, and crash recovery — now runs
through a single `RefinementJobQueue` actor instead of inline within
`RecordingViewModel`. The queue is FIFO, single-worker (one refine at a
time), persisted to JSONL via `RefinementJobStore`, and exposed through a
`@MainActor @Observable` view model. The refiner inside the queue
(`ResumableRefiner`) writes a `refine-progress.json` checkpoint in the
recording folder between every VAD region and every stage transition, so a
mid-run pause loses at most one in-flight region. The `RecordingStatus`
enum loses its `.refining` case: `stopRecording` enqueues the auto-refine
and returns to `.idle` immediately. Starting a recording pauses the queue
(closes a shared `PauseGate` *and* terminates the inflight pyannote
subprocess via a `Cancellable` seam); stopping resumes it. The `pulsartrace
refine` CLI continues to use `OfflineRefiner` directly (one-shot, no
queue) — its bare-WAV runs don't benefit from pause/resume.

**Why:** A real user issue: the prior design ran refinement inline in
`RecordingViewModel`, blocking new recordings until refine completed. For
back-to-back meetings — the common case — that was a deal-breaker. The
queue resolves three problems at once: (a) recording is exclusive and
prioritised (a refine pauses to give capture its CPU/RAM/Metal), (b)
refines survive across recording starts (resume from the on-disk
checkpoint), and (c) auto and manual refinement paths share the same
observable orchestrator, so the new Refinements sidebar pane shows a
single source of truth for both. The pyannote cancel-and-retry strategy
(D-Q7 internal) accepts up to one pyannote re-run per pause cycle —
~10–30s of model reload plus re-inference of the cancelled diarize —
which is well inside the user's "5 minutes of duplicated effort"
tolerance. The 8-stage refiner reports stage and region progress through
a `StageReporter` async closure, so the UI can show a fraction without
the queue and refiner sharing more surface than the `PauseGate`.

The architectural shape — actor + `@Observable` façade, polling 250 ms
snapshot, on-disk JSONL persistence — matches the existing
`RecordingsScanner`/`LiveTranscriptWatcher` patterns. The decision to keep
`OfflineRefiner` rather than fold the CLI onto the queue too is
deliberate: the CLI's bare-WAV path has no recording-vs-refine
interleaving to coordinate, and one-shot CLI semantics ("run once, exit")
are awkward with a long-lived queue actor and store.

## D35 — Refinement-queue UI polls at 250 ms; no `AsyncStream` push channel

**Decision:** `RefinementJobQueueViewModel` (the `@MainActor @Observable` façade in `Sources/PulsarTraceMenuBar/RefinementJobQueueViewModel.swift`) refreshes by polling `RefinementJobQueue.snapshot()` every 250 ms via a `Task` loop. We are not threading an `AsyncStream<Snapshot>` from inside the queue actor to the view model.

**Why:** Three reasons. (1) The pattern matches `LiveTranscriptWatcher` and `RecordingsScanner`, which both poll — consistency reduces the number of distinct UI-update shapes a future contributor has to learn. (2) `RefinementJobQueue.Snapshot` is `Equatable` and small (typically ≤ a few jobs); the VM mutates `@Observable` properties only on real change, so SwiftUI's diffing keeps steady-state work tiny — one actor hop and one struct comparison per tick, four times a second. (3) Push channels across an actor boundary into the MainActor introduce buffering and back-pressure questions (drop-oldest? coalesce? cancel?) that aren't justified by the workload — a refine emits at most one stage update every few seconds. Polling is the simpler design at this throughput.

## D36 (revised 2026-05-20) — `WhisperTranscriber` is reused across regions within a job

**Decision:** `RefinementJobQueue.makeStandard` builds one `WhisperTranscriber` per job via a `SharedTranscriberBox`, and the refiner's `transcribe:` closure pulls the same instance for every VAD region. `OfflineRefiner` / `RefinementPipeline.transcribe` already builds one transcriber per WAV (i.e. one per stream); the queue path now matches that locality.

**Why:** the original D36 decision held that per-region construction was negligible because the model file is mmapped, so the OS page cache amortised the cost. That reasoning was wrong on two fronts:

- The page cache covers the mmap'd weights only. `whisper_init_from_file_with_params` builds the **Metal pipeline state object**, allocates the KV cache, and initialises the GGML backend on every call — multi-second for `large-v3` on Apple Silicon, not "tens of ms".
- The claim that the per-region pattern "matches OfflineRefiner" was simply false — `RefinementPipeline.transcribe` already constructs the transcriber once per stream and reuses it across regions via `transcriber.transcribe(samples, regions:, options:)`.

Reopened after refining session `2026-05-20-100033` averaged ~78 s per VAD region of mostly short utterances — roughly two orders of magnitude slower than realistic decode time, dominated by repeated Metal pipeline initialisation. `SharedTranscriberBox` (a small `@unchecked Sendable` lazy single-instance wrapper) lets the existing `@Sendable` `transcribe:` closure capture the box and reuse one instance without changing `ResumableRefiner`'s public surface or breaking its unit tests. The queue is single-worker, so at most one box / one transcriber exists at any time, preserving D8's metalLock contract.

**Tradeoff:** holding the transcriber across a `pauseGate` close keeps ~3 GB resident for `large-v3` while the queue is paused for a recording. Accepted for v1 — the alternative (drop on pause, rebuild on resume) re-introduces the model-reload cost for the common short-pause case (stall recovery, hotkey toggle). If memory pressure surfaces in practice, a "drop after N seconds of idle pause" variant can be layered onto `SharedTranscriberBox` without changing call sites.

## D37 — `EventWriter.append` holds an advisory `flock(LOCK_EX)`

**Decision:** Every `EventWriter.append` call acquires `flock(LOCK_EX)` on the daily events file's fd before writing and releases it after. The events file is a shared resource between every process that links `PulsarTraceEngine` and writes — the capture daemon, the menubar app, and the CLI; the actor model only serialises within one process.

**Why:** an interleaved line was observed in `events/2026-05-20.jsonl` where a `recording_paused` from `pulsartrace-capture` was clobbered mid-write by an `app_stopped` from `pulsartrace-mac`. `flock` is cooperative — it only protects against other callers that also `flock` — but every writer of this file goes through `EventWriter`, so the contract is complete in-tree. Foundation's `FileHandle.write(contentsOf:)` resolves to a single `write(2)` system call, but `write(2)` is only atomic up to `PIPE_BUF` bytes; longer events would still split without the lock. The fix is the simplest thing that works and survives a hot rotation: the lock is per-fd and is released via `defer`.

## D38 — Live pass decouples the recording from transcription (drain + bounded-queue whisper worker + abort-watchdog)

**Decision:** `LiveRunner.run` is split into a recording-safe **drain** and a single best-effort whisper **worker**, connected by bounded per-stream queues. The drain writes the WAV first (the durable recording), feeds diarization, and enqueues frames onto a `BoundedFrameQueue` — it **never calls whisper**. The worker consumes the queues, runs the synchronous `whisper_full` decode, and writes utterances to the live.md sink. The recording (the WAVs) therefore never blocks on a whisper decode; live transcription is best-effort and recovers from a hang. The full design lives in `docs/specs/2026-05-22-live-pipeline-decoupling-design.md`.

**Why:** the live path was a single serial loop that did the WAV write and then the synchronous decode in sequence per frame, so a hung decode also stopped the WAV writes and lost part of the recording. This was root-caused via the phase-tracker heartbeat on session 2026-05-22 to a synchronous `whisper_full` decode wedging the loop — *not* the live-md sink or the speaker-library SQLite read previously hypothesized (see `docs/specs/2026-05-20-refine-perf-and-capture-resilience-plan.md`). Putting the durable recording write upstream of, and independent from, whisper makes the recording immune to a decode hang; what is dropped during a hang is only live-transcript audio, which the offline post-pass recovers.

The load-bearing facts a future reader needs:

- The `BoundedFrameQueue` is bounded and **drop-oldest** under backpressure; a one-time note in `live.md` marks that a drop occurred, so a slow/hung whisper loses live-transcript audio (recovered offline) but never blocks the drain.
- The worker offloads the blocking decode onto a `DispatchQueue`, so a wedged decode can't pin a cooperative-pool thread (which would starve the bounded teardown timer).
- A per-decode `DecodeWatchdog` arms a deadline: at the deadline it flips an `AbortToken` wired to whisper's `abort_callback`, so a hung/runaway decode bails and the worker resumes live transcription. A per-window `max_tokens` cap (256) additionally bounds a runaway decode.
- The abort only takes effect at encode/decode-**step** boundaries (not mid-graph) in this whisper build, so a hang *inside* a single step cannot be aborted — the watchdog's second stage only **monitors** that case, emitting an escalating "did not honor abort" warning so the unrecoverable hang is visible. It is not recoverable.
- `metalLock` serializes every `whisper_full` call process-wide, so a hung decode holds it; the abort is what releases it.

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

Diarization stays on Python/pyannote (MPS) for now — its ANE migration is
deferred to a separate plan (the speaker library stores pyannote embeddings;
switching models needs an embedding-space migration of its own).

**Why:** whisper.cpp's Metal decode pinned the GPU: live transcription
degraded Google Meet + screen-share fluency, and the large-v3 refine of a
1 h recording ran at ~1× real time while monopolising the GPU. The ANE is
idle during meetings; Parakeet v3 beats whisper base on Polish by ~4×
FLEURS WER (7.3% vs 30.8%); turbo is ~2–5× faster than large-v3 at
near-identical accuracy. CC-BY-4.0 (Parakeet) / Apache-2.0 (FluidAudio) /
MIT (WhisperKit, Whisper weights) all permit commercial use.

**Mechanics this changes:** refine wedge recovery is WhisperKit's
per-token callback deadline (return `false` → decode stops) instead of
SIGKILLing a subprocess; the queue's pause-release hook cancels the
in-flight decode at the next token boundary, drops the WhisperKit actor
(ARC frees the CoreML models), and requeues the job so it resumes from its
checkpoint after the recording. The live Parakeet decode is bounded by a
30 s semaphore deadline per window (skipped window, the post-pass
recovers). Speech regions come from FluidAudio's Silero-CoreML VAD with
the same 800 ms coalescing (`SpeechRegion.coalesced`); the D31
hallucination double-gate is ported onto WhisperKit's per-segment
`noSpeechProb`/`avgLogprob`. CoreML model bundles are SDK-managed
directories under `~/Library/Caches/PulsarTrace/models/`
(`AppPaths.modelsCacheDirectory`; D10 root preserved — the FluidAudio
silero-vad bundle is pinned under the same root at `silero-vad-coreml/`,
the SDK appending its own `Models/` subpath inside) with **no pinned
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

## D40 — Diarization moves to the Apple Neural Engine; the pyannote Python sidecar is removed

**Decision:** Speaker diarization now runs **fully in-process on the Apple
Neural Engine** via FluidAudio 0.15.2's `OfflineDiarizerManager` — both the
offline (refine) pass and the live (streaming) pass. The Python/pyannote
sidecar is **gone**: the entire `python/` tree is deleted (no venv, no
`requirements.lock`, no `build-venv.sh`, no `pulsartrace_ai.diarize` /
`pulsartrace_ai.live_diarize` modules), and with it the one-shot subprocess
(D9), the long-lived windowed-pyannote subprocess (D19), the Swift↔Python
JSON wire contract, the `HF_TOKEN`/`.env` arrangement, and the Hugging Face
gating flow. There is no embedded Python anywhere in the app. The revert
path, should ANE diarization disappoint, is `git revert` of this branch.

The models are FluidInference's CoreML conversion of
`pyannote/speaker-diarization-community-1` — the same model family the PRD
standardises on, ported to CoreML: powerset segmentation + WeSpeaker 256-d
speaker embeddings + AHC (agglomerative) warm start + a VBx/PLDA clustering
refinement. They are downloaded (~21 MB) from the **public** Hugging Face
repo `FluidInference/speaker-diarization-coreml` into
`~/Library/Caches/PulsarTrace/models/speaker-diarization/`. FluidAudio
derives that folder name by stripping the `-coreml` suffix from the repo
name, so the on-disk directory is `speaker-diarization/` even though the
repo is `…-coreml`. The `model_downloaded` event's `model_name` for this
bundle is `speaker-diarization-coreml` (the repo's short name). The repo is
public, so the model-download network call is governed by the D39 pattern
(SDK-managed download into the D10 cache root, no token, no gating); there
is no longer any gated download to fall back through a terms flow.

A new resident `DiarizerEngine` actor
(`Sources/PulsarTraceEngine/Diarization/DiarizerEngine.swift`) owns the
`OfflineDiarizerManager` and is loaded **once per process**; the live pass
shares that single resident instance. The offline `Diarizer` lazily loads
its **own** `OfflineDiarizerManager` per refine queue (one model load per
refine worker, not per job). R29 — one embedding space across live,
offline, and the speaker library — now holds **by construction**, because
all three paths run the same FluidAudio WeSpeaker model.

**Model identity (`modelRevision`):** there is no pinned SHA-256 and no
Hugging Face commit SHA anymore. `modelRevision` is the **DirectoryDigest**
— a deterministic SHA-256 tree hash of the model directory (the same
content-addressed digest D39 introduced for the WhisperKit/Parakeet/silero
bundles). It replaces the pyannote checkpoint's HF commit SHA from D12 and
carries **exactly the same Open-Question-#3 scoping semantics**: the speaker
library refuses to match centroids across a `modelRevision` change, so an
upstream bundle revision (which moves the embedding space) cannot silently
mis-match old speakers.

**VBx evidence weight raised — `clustering.warmStartFa = 0.2` (FluidAudio
default 0.07).** This is the one tuning deviation from FluidAudio's defaults
and a future maintainer must know it is deliberate. Measured on the
committed fixtures: at the default Fa 0.07 the VBx clusterer **collapses two
clearly-distinct voices into a single cluster** on recordings shorter than
~1 minute — even though the embeddings themselves separate cleanly
(cross-speaker cosine ~0.35–0.38, same-speaker ~0.93). The cause is the VBx
prior: with little audio accumulated, the prior dominates the per-frame
evidence and pulls everything into one speaker. The *same* 24 s two-speaker
clip that fuses at Fa 0.07 separates correctly when the clip is 72 s long.
Sweeping the parameter: every Fa in the range 0.08…0.3 separates the
two-speaker clip, and **none** of them splits a 2-minute single-voice concat
(i.e. raising Fa this far does not introduce spurious over-splitting on
single-speaker audio). Fa = 0.2 sits well clear of the 0.07/0.08 boundary
where the behaviour flips. **Rationale:** the failure modes are not
symmetric. Under-separation — two real people fused under one label — has
**no post-hoc remedy** (the embeddings were averaged together; you cannot
un-mix them). Over-split — one person spread across two labels — is fully
recoverable with the speaker-merge tool. So we bias the parameter toward
splitting, and 0.2 buys a wide safety margin against the under-separation
cliff while staying inside the no-spurious-split band.

**Thresholds recalibrated for the WeSpeaker embedding space.** pyannote's
256-d space and WeSpeaker's 256-d space are different geometries, so the
old cosine thresholds do not transfer. Measured on fixtures: same-speaker
similarity ~0.93, cross-speaker ~0.35. Accordingly:
`SpeakerLibrary.defaultMatchThreshold` lowered 0.7 → **0.45**, and
`LiveDiarizer.stitchThreshold` lowered 0.55 → **0.45**. 0.45 sits roughly
midway between the ~0.35 cross-speaker floor and the ~0.93 same-speaker
ceiling. These numbers are pinned by the `DiarizationE2E threshold
calibration` suite so a future embedding-space change that shifts them will
fail loudly.

**Live pass — geometry and algorithm unchanged, inference moved in-process.**
`LiveDiarizer` keeps the 10 s window / 5 s step geometry and the
embedding-stitching algorithm (per-window labels stitched into stable
provisional `Them`/`Them #N` keys by cosine match against running live
centroids); only the per-window inference is now an in-process
`DiarizerEngine` call instead of a JSON round-trip to the Python subprocess.
Measured: a **single 10 s window does not separate two voices** on its own —
speaker differentiation emerges from stitching the per-window results across
windows, exactly as before. The R16 best-effort/provisional posture is
unchanged (the post-pass remains the source of truth), and R29 now spans
live + offline + library by construction (above).

**Offline `Diarizer` — structurally identical, mechanism swapped.** Same
type name, same `diarizeSystemStream(wavPath:)` entry point (R17 structural
invariant intact — mic is never diarized), same `RefinementCancellable`.
Cancellation (queue pause, D-Q7) now maps onto Swift `Task` cancellation:
FluidAudio calls `Task.checkCancellation()` inside its compute loop, so a
pause genuinely **stops compute** rather than SIGKILLing a subprocess; the
`.cancelled` case is kept so the D-Q7 pause/requeue/retry loop is untouched.
The timeout watchdog is kept as well — effective timeout = max(600 s floor,
the audio's real-time length).

**Speaker library schema v3.** The column `pyannote_model_revision` is
renamed to `model_revision`. On first open of any pre-v3 database (detected
by the presence of the old column — this covers both v1 and v2), the entire
file is archived to `speakers.sqlite.pre-v3.bak` via `VACUUM INTO` and the
live database is reset. This is mandatory, not cosmetic: pyannote-space
centroids can never meaningfully match WeSpeaker embeddings, so carrying
them forward would only produce garbage matches. After the reset, known
speakers simply re-emerge as `Unknown #N` on the next refine and can be
renamed/merged as usual.

**`metadata.json` schema v2.** The `pyannote_model` field becomes
`diarization_model { id, revision }`, and the old `library_version` field is
dropped (there is no Python library version to record anymore). `id` is the
model identity, `revision` is the DirectoryDigest above.

**Doctor / preflight.** The `doctor` command no longer probes a Python
environment (there is none). It checks the **model cache** instead —
presence/health of the diarization bundle under the D10 cache root, the
same way it now checks the WhisperKit/Parakeet bundles after D39.

**Why:** the ANE is idle during meetings and the in-process port removes an
entire embedded-Python runtime — its venv, its torch/onnx pin set, its
subprocess lifecycle, its gated-download/token flow, and its telemetry
kill-switch — from the shipping app. CoreML diarization is ~21 MB versus a
multi-gigabyte torch install, runs on the Neural Engine alongside the D39
transcription models, and unifies the embedding space across every pass. The
licences permit commercial use (FluidAudio Apache-2.0; the community-1 model
family as published by FluidInference).

**Supersedes / reshapes earlier decisions:** this entry **supersedes D9**
(the one-shot pyannote diarization subprocess) and **D19** (windowed-pyannote
as the live diarizer over `diart`) outright. It supersedes the
pyannote-specific halves of **D10** (the `HF_HOME` redirect — moot: FluidAudio
downloads straight into the cache root, so there is no `HF_HOME` to set; the
shared-cache-root rationale survives via the D10/D39 root) and **D12** (the
OpenTelemetry kill-switch — moot: there is no Python pyannote process to
emit telemetry; the only diarization network call is the public-repo model
download, governed by the D39 pattern). D12's `model_revision` *field*
survives but is now the DirectoryDigest rather than an HF commit SHA, with
the same Open-Question-#3 cross-revision-refusal semantics. D11's diarization
JSON `schema` field and Swift↔Python wire contract are retired along with
the subprocess (the dominant-overlap merge and 30% co-attribution logic in
`DiarizationMerge` are unchanged — they operate on the in-process result the
same way). **PRD §17's "pyannote stays in Python" is superseded** here, the
same way D39 superseded the PRD's whisper.cpp sections. This **completes the
diarization deferral** explicitly noted in D39.
