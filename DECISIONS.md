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
