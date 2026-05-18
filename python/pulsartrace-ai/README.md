# pulsartrace-ai

The **speaker-diarization layer** of PulsarTrace — a small Python package the
Swift engine runs as a captive subprocess. whisper.cpp transcription stays in
Swift; [pyannote.audio](https://github.com/pyannote/pyannote-audio) diarization
stays here. The two never mix in one process.

This is a sub-package of the [PulsarTrace](../../README.md) repository, not a
standalone project. It is not published to PyPI — it is built into a local venv
and invoked over an IPC boundary by the Swift `Diarizer` / `LiveDiarizer`.

## What it does

It loads `pyannote/speaker-diarization-community-1` (pyannote.audio 4.x — a
gated model needing a Hugging Face token) and answers the question *"who spoke
when?"* for a recording's **system stream**. The microphone stream is never
diarized — "You" is always "You" (PRD R17).

Two entry points, two execution models:

| Module | Invocation | Used by | Lifetime |
|---|---|---|---|
| `pulsartrace_ai.diarize` | `python -m pulsartrace_ai.diarize <wav>` | offline `refine` pass | one-shot per recording |
| `pulsartrace_ai.live_diarize` | long-lived; newline-JSON stdin/stdout | live streaming pass | one process per meeting |

Both emit speaker spans plus per-speaker 256-d pyannote embeddings, so a voice
is cross-comparable between the live pass, the offline pass, and the persistent
speaker library. The exact JSON contracts are documented in each module's
docstring — `diarize.py` (output object) and `live_diarize.py` (the per-window
request/response protocol) — and are the source of truth for the Swift side.

`live_diarize` uses **windowed-pyannote**, not `diart`: `diart` would resolve
`pyannote.audio` down to 3.4.0 and break the 4.x offline model. See
[`DECISIONS.md`](../../project-docs/DECISIONS.md) D19.

## Layout

```
pulsartrace_ai/
  __init__.py        version string
  diarize.py         offline diarization — one-shot CLI subprocess
  live_diarize.py    live diarization — long-lived windowed subprocess
tests/
  conftest.py        session-scoped pyannote pipeline fixture; offline-HF setup
  test_diarize.py    real pyannote on committed audio fixtures
  test_live_diarize.py
pyproject.toml       package metadata + ruff/pytest config (direct deps only)
requirements.lock    the full pinned transitive closure — what is installed
```

## Build & test

The venv is created from Homebrew's `python@3.12`, pinned via
`requirements.lock`. Run the build script from the repo root:

```bash
python/build-venv.sh        # creates .venv, installs the lock, then prefetches the model
```

`build-venv.sh` ends by running `python/prefetch-model.sh`, which downloads the
gated pyannote model **once** (online, with `HF_TOKEN` set or in the repo
`.env`) into PulsarTrace's own Hugging Face cache at
`~/Library/Caches/PulsarTrace/huggingface` (not the shared `~/.cache`, per
`DECISIONS.md` D10).

Run the test suite:

```bash
.venv/bin/pytest                       # from this directory
# or, from the repo root:
( cd python/pulsartrace-ai && .venv/bin/pytest )
```

The diarization tests run **real pyannote** on the committed audio fixtures in
`Tests/Fixtures/audio/`. `conftest.py` points Hugging Face at the local cache
and forces offline mode, so the suite runs anywhere — including inside the
Claude Code Bash sandbox — with **zero network**. A test that needs the model
skips cleanly, naming `prefetch-model.sh`, when the cache is empty.

Tests are deterministic: torch / numpy / `random` are seeded (`RANDOM_SEED`),
so a given WAV diarizes identically run to run.

## Privacy — no telemetry

pyannote.audio 4.x ships default-on OpenTelemetry metrics that would POST
pipeline metadata to a remote endpoint on every call. `diarize.py` sets
`PYANNOTE_METRICS_ENABLED=false` **before** importing pyannote and also calls
`set_telemetry_metrics(False)`; the Swift parent injects the same env var into
the subprocess as defence in depth. See `DECISIONS.md` D12. This upholds
PulsarTrace's Hard Invariant #1: *no telemetry, ever.*

## Further reading

- [`../../README.md`](../../README.md) — the project overview
- [`../../project-docs/PRD.md`](../../project-docs/PRD.md) — requirements (R15–R17, R29, R60)
- [`../../project-docs/DECISIONS.md`](../../project-docs/DECISIONS.md) — D9/D10 (model + cache), D12 (telemetry), D19 (windowed-pyannote)
- [`../../project-docs/PREWORK.md`](../../project-docs/PREWORK.md) — dev host + sandbox model
