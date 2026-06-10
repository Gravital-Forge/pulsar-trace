"""Shared helpers for the offline (``diarize``) and streaming (``live_diarize``)
entry points.

Both entry points need the same error type, span shape, RNG seeding, model
revision lookup, annotation flattening and WAV duration probe. Giving them a
single home here means neither module imports the other's underscore-private
internals — a refactor of either entry point cannot silently break the other.

This module must not import from ``pulsartrace_ai.diarize`` or
``pulsartrace_ai.live_diarize`` (it would create an import cycle).
"""

from __future__ import annotations

import dataclasses
import math
import os
import random
import sys
import wave
from pathlib import Path
from typing import Any

# The gated pyannote model PulsarTrace standardises on (PRD §17).
MODEL_ID = "pyannote/speaker-diarization-community-1"

# Fixed RNG seed. pyannote's clustering has stochastic steps; seeding torch,
# numpy and Python's `random` makes a given WAV diarize identically run to run
# (PRD §12 determinism rule).
RANDOM_SEED = 1729


class DiarizationError(RuntimeError):
    """Raised for any condition that should fail the subprocess cleanly.

    The Swift ``Diarizer`` distinguishes a clean non-zero exit with a tagged
    stderr message from a crash; this carries the human-readable reason.
    """


@dataclasses.dataclass(frozen=True)
class Span:
    """One speaker turn: a label active over ``[start, end]`` seconds."""

    speaker: str
    start: float
    end: float

    def as_dict(self) -> dict[str, Any]:
        return {
            "speaker": self.speaker,
            "start": round(self.start, 3),
            "end": round(self.end, 3),
        }


def _seed_everything() -> None:
    """Seed every RNG pyannote can reach so diarization is deterministic.

    Note: `PYTHONHASHSEED` is *not* set here — by the time this module runs the
    interpreter has already started, so mutating `os.environ["PYTHONHASHSEED"]`
    has no effect on hash randomisation. The Swift `Diarizer` instead exports
    `PYTHONHASHSEED` into the subprocess environment before launch, where it
    actually takes effect.
    """
    random.seed(RANDOM_SEED)
    import numpy as np
    import torch

    np.random.seed(RANDOM_SEED)
    torch.manual_seed(RANDOM_SEED)
    if torch.backends.mps.is_available():
        torch.mps.manual_seed(RANDOM_SEED)
    # Require deterministic algorithm selection. If a kernel on this hardware
    # has no deterministic variant pyannote's inference path will raise — we
    # surface that rather than silently producing non-reproducible output
    # (PRD §12 determinism rule). Verified to pass on the Apple-Silicon MPS
    # path with pyannote community-1 / torch 2.12.
    torch.use_deterministic_algorithms(True, warn_only=False)


def _wav_duration_seconds(wav_path: Path) -> float:
    """Duration of a WAV file in seconds, read from its header."""
    with wave.open(str(wav_path), "rb") as w:
        frames = w.getnframes()
        rate = w.getframerate()
        if rate <= 0:
            # Basename only — the operational log must never carry full user
            # file paths (PRD §11 / R59, Hard Invariant #7).
            raise DiarizationError(
                f"WAV has invalid sample rate: {wav_path.name}"
            )
        return frames / float(rate)


def _model_revision(token: str | None = None) -> str:
    """The Hugging Face hub commit SHA of the diarization model checkpoint.

    The speaker library refuses to match centroids across a *model* change
    (Open Question #3). The pyannote.audio *library* version is not a
    reliable proxy for that — the same library can load different checkpoints,
    and a checkpoint can be re-uploaded under the same library version. So we
    record the model repo's commit SHA: the actual checkpoint identity.

    Resolved offline-first from the local snapshot already in the HF cache
    (community-1 is downloaded before this runs); falls back to a hub query
    only if that fails. Returns ``""`` if neither is reachable — the caller
    keeps the library version as the secondary identity field.
    """
    # Prefer the locally cached snapshot's revision so this needs no network.
    try:
        from huggingface_hub import constants as hf_constants
        from huggingface_hub.file_download import repo_folder_name

        cache_root = Path(os.environ.get("HF_HOME", hf_constants.HF_HOME)) / "hub"
        repo_dir = cache_root / repo_folder_name(repo_id=MODEL_ID, repo_type="model")
        main_ref = repo_dir / "refs" / "main"
        if main_ref.is_file():
            sha = main_ref.read_text().strip()
            if sha:
                return sha
    except Exception:  # noqa: BLE001 — fall through to a hub query
        pass

    try:
        from huggingface_hub import model_info

        info = model_info(MODEL_ID, token=token or os.environ.get("HF_TOKEN") or None)
        return info.sha or ""
    except Exception as exc:  # noqa: BLE001 — revision is best-effort
        print(f"[diarize] model revision unavailable: {exc}", file=sys.stderr)
        return ""


def _embeddings_by_label(
    raw_embeddings, speakers: list[str]
) -> tuple[dict[str, list[float]], int, list[str]]:
    """Map sorted speaker labels to embedding rows, dropping non-finite rows.

    pyannote can emit a NaN embedding row when a cluster has no usable
    speech frames (e.g. a near-silent recording). A non-finite row would
    crash JSON serialization (``allow_nan=False``) and is useless to the
    speaker library, so it is dropped here; the speaker keeps its spans
    and its pyannote display label (the Swift reconciler treats a label
    with no embedding as unmatchable and keeps the label as-is).

    Returns ``(embeddings, embedding_dim, dropped_labels)``.
    """
    if raw_embeddings is None or len(raw_embeddings) == 0:
        return {}, 0, []

    embedding_dim = int(raw_embeddings.shape[1])
    embeddings: dict[str, list[float]] = {}
    dropped_labels: list[str] = []
    for index, label in enumerate(speakers):
        if index < len(raw_embeddings):
            row = [float(x) for x in raw_embeddings[index]]
            if all(math.isfinite(x) for x in row):
                embeddings[label] = row
            else:
                dropped_labels.append(label)
    return embeddings, embedding_dim, dropped_labels


def _annotation_to_spans(annotation) -> list[Span]:
    """Flatten a pyannote ``Annotation`` into time-ordered ``Span`` objects."""
    spans = [
        Span(speaker=str(label), start=float(segment.start), end=float(segment.end))
        for segment, _, label in annotation.itertracks(yield_label=True)
    ]
    spans.sort(key=lambda s: (s.start, s.end, s.speaker))
    return spans
