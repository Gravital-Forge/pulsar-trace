# PT-P1 · v0.1 Offline Core — Decision Log

The choices that shaped the offline core, recorded as each was taken. Frozen at project close.

## Decisions

### PT-P1-D1 · Scope to the offline CLI core

*2026-05-15*

**Decision:** Deliver the offline pipeline as a command-line tool — no device capture, no live pass,
no UI — as v0.1.

**Because:** The initial build host had no audio devices, display, or signing identity; the offline
path is fully exercisable from fixtures and pipes, so it ships value first while later capabilities
build on its abstractions.

### PT-P1-D2 · Pure SwiftPM package, no Xcode project

*2026-05-15*

**Decision:** Build as a SwiftPM package — a library plus thin executables — with no `.xcodeproj`,
app bundle, or UI target.

**Because:** Everything in scope is headless and testable from the command line; an app bundle is
only needed once there is a UI.

### PT-P1-D3 · Diarization runs in a pinned Python environment

*2026-05-16*

**Decision:** Run diarization in a Python virtual environment built from a Homebrew `python3.12` and
pinned by a lockfile, invoked from Swift; bundling a self-contained Python runtime is deferred to
the distribution phase.

**Because:** The strongest open diarization model ships as a Python library; a Homebrew-built,
pinned venv keeps results reproducible and the Swift side thin during development, leaving the
heavier self-contained-runtime packaging for later.

### PT-P1-D4 · Tests use the small recognition model

*2026-05-16*

**Decision:** The test suite transcribes with the small `base` model; the larger model stays the
documented refinement default.

**Because:** Model choice is a runtime knob; the small model keeps tests fast and deterministic
without changing the code under test.

### PT-P1-D5 · Serialize the app-version field as `app_version`

*2026-05-16*

**Decision:** Lifecycle events serialize their application-version field as `app_version`.

**Because:** The event envelope already owns a top-level `version` field; a distinct name avoids a
collision.

### PT-P1-D6 · Test fixtures resolved by source path

*2026-05-16*

**Decision:** Audio fixtures live in a fixed directory resolved via the compiled source-file path,
not as package bundle resources.

**Because:** Bundle resources duplicated the fixtures and collided under case-insensitive
filesystems; a path-relative lookup avoids both.

### PT-P1-D7 · Transcription via a vendored native engine

*2026-05-16*

**Decision:** Transcription uses a native speech-recognition engine vendored from source at a pinned
version, built with GPU acceleration and linked through a C interop target.

**Because:** A resident, in-process engine over a stable C API gives low-latency transcription with
no per-call process spawn, and pinning the source keeps builds reproducible.

### PT-P1-D8 · Single-context lock around the GPU recognizer

*2026-05-16*

**Decision:** Recognizer context creation, destruction, and inference are guarded by a process-wide
lock, and the recognition test suite runs serialized.

**Because:** Concurrent GPU contexts corrupt each other; serializing access is the reliable remedy.

### PT-P1-D9 · Diarization as a one-shot subprocess

*2026-05-16*

**Decision:** Offline diarization runs as a one-shot Python subprocess — WAV in, JSON out — with a
timeout and stderr captured to the operational log.

**Because:** A one-shot process is simple and crash-isolated; the JSON contract keeps the
Swift/Python boundary explicit.

### PT-P1-D10 · Model cache under a single product root

*2026-05-16*

**Decision:** Downloaded model data is cached under one PulsarTrace-owned cache directory.

**Because:** Keeping all model data under one root keeps it from being evicted by unrelated cache
wipes and makes the footprint auditable.

### PT-P1-D11 · Typed diarization contract and dominant-overlap merge

*2026-05-16*

**Decision:** The diarization JSON carries a schema version; the transcript-to-turns merge
attributes each utterance to the speaker with dominant time overlap, co-attributing a second speaker
that covers a large minority.

**Because:** A versioned contract lets the wire format evolve safely, and dominant-overlap is a
robust, explainable attribution rule.

### PT-P1-D12 · Disable the diarization library's telemetry exporter

*2026-05-16*

**Decision:** The diarization library's default-on telemetry exporter is force-disabled before
import and at the call site, and a model-revision identifier is added to the output.

**Because:** The product sends nothing off-device; an automatic exporter would violate that, and the
revision identifier makes results traceable to a specific checkpoint.

### PT-P1-D13 · Bare-WAV refine writes a sibling folder

*2026-05-16*

**Decision:** Refining a bare WAV creates a sibling recording folder named for the file and writes
all outputs there, leaving the original untouched.

**Because:** The original file is the user's; a sibling folder keeps inputs and generated artifacts
cleanly separated.

### PT-P1-D14 · Atomic writes with backups; a cross-suite recognizer gate

*2026-05-16*

**Decision:** Generated transcripts and metadata are written temp-then-rename on the same volume
with prior versions kept as backups; a process-wide gate serializes recognizer use across test
suites.

**Because:** Atomic writes make a crash unable to leave a truncated transcript; the gate prevents
cross-suite GPU contention from flaking tests.

### PT-P1-D15 · Tests force the CPU recognition backend

*2026-05-16*

**Decision:** Tests construct the recognizer on its CPU backend; production uses the GPU backend.

**Because:** An exit-time GPU teardown assertion crashed the test process; the CPU backend sidesteps
it without affecting production behaviour.

### PT-P1-D16 · Library edits are not retroactive in this project

*2026-05-16*

**Decision:** Speaker rename and merge in this project update only the library, not previously
written transcripts; retroactive rewrite is left to a later project.

**Because:** Retroactive rewrite needs a recording-appearance index and atomic multi-file rewrite
that are larger than this project's scope.

### PT-P1-D17 · Speaker library on the built-in SQLite module

*2026-05-16*

**Decision:** The speaker library is a hand-rolled wrapper over the system SQLite module rather than
a third-party package.

**Because:** SQLite ships with the platform; using it directly avoids a dependency for a small,
well-understood surface.

### PT-P1-D18 · Unmerge restores the centroid arithmetically

*2026-05-16*

**Decision:** Reversing a speaker merge reconstructs the primary speaker's pre-merge centroid by
inverting the count-weighted-mean arithmetic, with a documented fallback when inversion is inexact.

**Because:** Inverting the arithmetic restores the exact prior state without storing centroid
history.
