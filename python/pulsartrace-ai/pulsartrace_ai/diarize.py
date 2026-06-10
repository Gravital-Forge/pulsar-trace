"""Offline speaker diarization for PulsarTrace.

This module is the captive-subprocess entry point the Swift engine spawns to
diarize a recording's **system stream**. It loads
``pyannote/speaker-diarization-community-1`` (pyannote.audio 4.x, a gated model
that needs a Hugging Face token), runs it on a WAV file, and emits a single
JSON object on **stdout** describing speaker spans plus per-speaker embeddings.

Architecture (see ``.claude/skills/pulsartrace-execution`` and PRD §17):

* whisper.cpp stays in Swift; pyannote stays here in Python. Never mixed.
* The Swift ``Diarizer`` invokes this as a **one-shot** subprocess per refine —
  pass a WAV path, get JSON back. The long-lived live diarization runtime is a
  separate concern (``live_diarize.py``) and is *not* built here.
* **R17**: only the system-stream WAV is ever passed in. The mic stream is
  never diarized — "You" is always "You". This module has no notion of a mic
  stream by construction; it diarizes exactly the file it is handed.
* **R29**: embeddings come straight from pyannote's own pipeline so they are
  cross-comparable with the live pass and the persistent speaker library. The
  model checkpoint's Hugging Face commit SHA (``model_revision``) is carried
  in the output so the speaker library can refuse to match centroids across a
  model change (Open Question #3); the pyannote.audio library version is
  carried alongside it as a secondary identity field.

Output JSON contract (consumed by Swift ``Diarizer``)::

    {
      "schema": 1,
      "model": "pyannote/speaker-diarization-community-1",
      "model_revision": "<HF hub commit SHA of the model checkpoint>",
      "model_version": "<pyannote.audio library version>",
      "audio_duration": 32.0,
      "speakers": ["SPEAKER_00", "SPEAKER_01"],
      "spans": [
        {"speaker": "SPEAKER_00", "start": 0.031, "end": 8.452},
        ...
      ],
      "exclusive_spans": [ ... ],          # overlap-resolved (no two speakers
                                           # active at once); same shape
      "embeddings": {
        "SPEAKER_00": [0.12, -0.03, ...],  # 256-d float vector, pyannote space
        "SPEAKER_01": [ ... ]
      },
      "embedding_dim": 256
    }

``spans`` preserves overlapping speech: when two speakers talk at once both
attributions appear (their spans simply overlap in time). ``exclusive_spans``
is pyannote 4.x's overlap-resolved variant, handy for clean transcript
reconciliation. Times are seconds from the start of the WAV.

The model is cached under PulsarTrace's own cache dir (``HF_HOME`` is pointed
at ``~/Library/Caches/PulsarTrace/huggingface``) rather than the shared
``~/.cache/huggingface`` — see ``DEFAULT_CACHE_DIR`` and DECISIONS.md D10.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os

# --- Telemetry kill switch (Hard Invariant #1: "No telemetry, ever") ---------
# pyannote.audio 4.0.4 ships default-on OpenTelemetry metrics. Its
# `pyannote/audio/telemetry/metrics.py` builds an `OTLPMetricExporter` +
# `PeriodicExportingMetricReader` (a background daemon thread) at import time
# and `track_pipeline_apply()` would POST pipeline name / version / a session
# UUID / speaker counts to `https://otel.pyannote.ai/v1/metrics` on every
# `pipe()` call — but only when `is_metrics_enabled()` is true, which it gates
# on the `PYANNOTE_METRICS_ENABLED` env var. Setting that var to "false" BEFORE
# pyannote is imported means no metric is ever recorded, so the periodic
# exporter has nothing to send and never makes a network call. We also call the
# explicit `set_telemetry_metrics(False)` API after import as belt-and-braces.
# See DECISIONS.md D12. The Swift Diarizer additionally injects this same env
# var into the subprocess environment (defence in depth).
os.environ["PYANNOTE_METRICS_ENABLED"] = "false"

import sys
from pathlib import Path
from typing import Any

from pulsartrace_ai._common import (  # noqa: F401 — re-exported for compat
    DiarizationError,
    MODEL_ID,
    Span,
    _annotation_to_spans,
    _model_revision,
    _seed_everything,
    _wav_duration_seconds,
)

# Output schema version. Bump on a breaking change to the JSON contract; the
# Swift Diarizer keys off it.
SCHEMA_VERSION = 1


def default_cache_dir() -> Path:
    """PulsarTrace's Hugging Face cache directory.

    Per DECISIONS.md D10 the pyannote model is cached under PulsarTrace's own
    cache root, not the shared ``~/.cache/huggingface``, so uninstalling the
    app reclaims the space and a system-wide HF cache wipe cannot evict it.
    """
    return (
        Path.home()
        / "Library"
        / "Caches"
        / "PulsarTrace"
        / "huggingface"
    )


@dataclasses.dataclass(frozen=True)
class DiarizationResult:
    """Full diarization output for one WAV — serialises to the JSON contract."""

    model_revision: str
    model_version: str
    audio_duration: float
    speakers: list[str]
    spans: list[Span]
    exclusive_spans: list[Span]
    embeddings: dict[str, list[float]]
    embedding_dim: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA_VERSION,
            "model": MODEL_ID,
            "model_revision": self.model_revision,
            "model_version": self.model_version,
            "audio_duration": round(self.audio_duration, 3),
            "speakers": self.speakers,
            "spans": [s.as_dict() for s in self.spans],
            "exclusive_spans": [s.as_dict() for s in self.exclusive_spans],
            "embeddings": self.embeddings,
            "embedding_dim": self.embedding_dim,
        }


def _hf_token() -> str:
    """The Hugging Face token, required for the gated community-1 model.

    Read from the ``HF_TOKEN`` environment variable. In development the Swift
    layer / a developer loads it from ``.env``; production moves it to the
    macOS Keychain and exports it into this subprocess's environment the same
    way. Either way this module only ever sees an env var.
    """
    token = os.environ.get("HF_TOKEN", "").strip()
    if not token:
        raise DiarizationError(
            "HF_TOKEN is not set — pyannote community-1 is a gated model and "
            "requires a Hugging Face access token. See "
            "https://huggingface.co/pyannote/speaker-diarization-community-1"
        )
    return token


def load_pipeline(
    token: str | None = None, cache_dir: Path | None = None
) -> "pyannote.audio.Pipeline":
    """Load the pyannote diarization pipeline, cached under PulsarTrace's dir.

    Pointing ``HF_HOME`` at PulsarTrace's cache must happen *before* any
    huggingface_hub import resolves it, so this sets the env var first.
    """
    cache = cache_dir or default_cache_dir()
    cache.mkdir(parents=True, exist_ok=True)
    # HF_HOME is the umbrella var huggingface_hub 1.x honours for hub + models.
    os.environ.setdefault("HF_HOME", str(cache))

    import pyannote.audio
    from pyannote.audio import Pipeline

    # Belt-and-braces: the import above already saw PYANNOTE_METRICS_ENABLED
    # set to "false" (module top), so no metric is ever recorded — but call the
    # explicit disable API too, so no future pyannote refactor can re-enable it
    # and no exporter daemon is left doing work. Hard Invariant #1 / D12.
    try:
        pyannote.audio.telemetry.metrics.set_telemetry_metrics(False)
    except Exception as exc:  # noqa: BLE001 — telemetry API is best-effort
        print(f"[diarize] telemetry-disable API unavailable: {exc}", file=sys.stderr)

    pipeline = Pipeline.from_pretrained(MODEL_ID, token=token or _hf_token())
    if pipeline is None:
        raise DiarizationError(
            f"Pipeline.from_pretrained returned None for {MODEL_ID} — the "
            "token may lack access (accept the model terms on Hugging Face)."
        )

    # Use the MPS GPU when available (Apple Silicon); pyannote falls back to
    # CPU otherwise. Wrapped defensively: a `.to()` failure must not abort an
    # otherwise-runnable CPU diarization.
    try:
        import torch

        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
    except Exception as exc:  # noqa: BLE001 — best-effort device move
        print(f"[diarize] MPS unavailable, using CPU: {exc}", file=sys.stderr)

    return pipeline


def diarize(
    wav_path: Path,
    pipeline: "pyannote.audio.Pipeline | None" = None,
) -> DiarizationResult:
    """Run offline diarization on one system-stream WAV.

    - Seeds RNGs for determinism.
    - The community-1 pipeline returns per-speaker embeddings from its own
      embedding model by default (R29) — they are read off
      ``output.speaker_embeddings``.
    - Preserves overlapping speech in ``spans``; also surfaces pyannote 4.x's
      overlap-resolved ``exclusive_diarization``.
    - Single-speaker input yields exactly one speaker and no ghost speakers —
      pyannote's clustering degrades gracefully and this code adds nothing
      that would invent extra labels.

    ``pipeline`` may be injected (tests reuse one loaded pipeline across
    fixtures to avoid paying the ~10–30s model load per case).
    """
    wav_path = Path(wav_path)
    if not wav_path.is_file():
        # Basename only — the operational log must never carry full user
        # file paths (PRD §11 / R59, Hard Invariant #7).
        raise DiarizationError(f"WAV file not found: {wav_path.name}")

    _seed_everything()
    pipe = pipeline if pipeline is not None else load_pipeline()

    import pyannote.audio

    model_version = pyannote.audio.__version__
    model_revision = _model_revision()
    duration = _wav_duration_seconds(wav_path)

    # community-1's pipeline emits a DiarizeOutput with speaker_diarization,
    # exclusive_speaker_diarization and speaker_embeddings — no extra kwargs
    # needed; the embeddings come from pyannote's own embedding model (R29).
    output = pipe(str(wav_path))

    diarization = output.speaker_diarization
    exclusive = output.exclusive_speaker_diarization
    raw_embeddings = output.speaker_embeddings  # ndarray (n_speakers, dim)

    # pyannote returns embedding rows aligned with the speaker labels in
    # sorted order; map each label to its row explicitly so the JSON is
    # unambiguous regardless of how a future pyannote version orders things.
    speakers = sorted(str(label) for label in diarization.labels())

    embeddings: dict[str, list[float]] = {}
    embedding_dim = 0
    if raw_embeddings is not None and len(raw_embeddings) > 0:
        embedding_dim = int(raw_embeddings.shape[1])
        for index, label in enumerate(speakers):
            if index < len(raw_embeddings):
                row = raw_embeddings[index]
                embeddings[label] = [float(x) for x in row]

    return DiarizationResult(
        model_revision=model_revision,
        model_version=model_version,
        audio_duration=duration,
        speakers=speakers,
        spans=_annotation_to_spans(diarization),
        exclusive_spans=_annotation_to_spans(exclusive),
        embeddings=embeddings,
        embedding_dim=embedding_dim,
    )


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m pulsartrace_ai.diarize",
        description=(
            "Offline speaker diarization for PulsarTrace. Runs pyannote "
            "community-1 on a system-stream WAV and prints JSON on stdout."
        ),
    )
    parser.add_argument("wav", type=Path, help="path to a 16kHz mono WAV file")
    parser.add_argument(
        "--output",
        choices=["json"],
        default="json",
        help="output format (only 'json' is supported)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """CLI entry point: ``python -m pulsartrace_ai.diarize <wav>``.

    JSON goes to **stdout**; diagnostics go to **stderr** (which the Swift
    parent pipes into the operational log tagged ``[python]``, R60). Exit code
    0 on success, 1 on a clean ``DiarizationError``, 2 on an unexpected crash.
    """
    args = _build_arg_parser().parse_args(argv)
    try:
        result = diarize(args.wav)
    except DiarizationError as exc:
        print(f"[diarize] error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — surface any crash to the log
        print(f"[diarize] unexpected failure: {exc!r}", file=sys.stderr)
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 2

    # allow_nan=False: a NaN/Inf embedding value raises a clean ValueError
    # here (caught as an unexpected failure → exit 2) instead of emitting
    # `NaN`/`Infinity` tokens that Swift's strict JSONDecoder would reject.
    json.dump(
        result.as_dict(), sys.stdout, separators=(",", ":"), allow_nan=False
    )
    sys.stdout.write("\n")
    sys.stdout.flush()
    print(
        f"[diarize] ok: {len(result.speakers)} speaker(s), "
        f"{len(result.spans)} span(s), dim={result.embedding_dim}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
