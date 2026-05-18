"""Live (streaming) speaker diarization for PulsarTrace.

This module is the captive-subprocess entry point the Swift engine spawns for
the **live pass** — provisional, best-effort speaker IDs for the system stream
while a meeting is in progress (PRD R15/R16). The offline ``diarize`` module
remains the source of truth; this is the low-latency companion.

## Why windowed-pyannote, not diart (Open Question #1 — see DECISIONS.md D19)

The PRD recommended ``diart`` for the live pass. ``diart`` cannot be installed
here without breaking the working offline diarization: ``pip install diart``
resolves ``pyannote.audio`` **down to 3.4.0** (and ``numpy`` to 1.26.4), but
the offline pass standardised on ``pyannote/speaker-diarization-community-1``
which requires pyannote.audio **4.x**. Downgrading would break offline
diarization and the speaker-library centroids' cross-comparability (R29). The
PRD's §16 explicitly lists *windowed-pyannote* as the viable alternative, so
that is what this module implements.

## Protocol — a long-lived subprocess, not one-shot per chunk

The Swift ``LiveDiarizer`` launches this module **once** and keeps it alive for
the whole recording (the model load is paid once, ~10-30 s). It then drives it
over a simple newline framed stdin/stdout protocol:

* The engine writes one **request line** of JSON per window to stdin::

      {"window_wav": "/tmp/…/win-000123.wav", "window_start": 12.0}

  ``window_wav`` is a freshly written WAV holding a recent slice of the system
  stream; ``window_start`` is that slice's offset from the recording start.

* This process diarizes that one window and writes one **response line** of
  JSON to stdout::

      {"window_start": 12.0, "speakers": ["SPEAKER_00", "SPEAKER_01"],
       "spans": [{"speaker": "SPEAKER_00", "start": 12.0, "end": 14.5}],
       "embeddings": {"SPEAKER_00": [...]}, "embedding_dim": 256,
       "infer_ms": 1820.4}

  ``infer_ms`` is the wall time of the pyannote call for that window — the
  dominant cost of the live pass. The Swift side logs it per window and the
  timing test asserts it stays within the window timeout.

  Span/embedding shapes mirror ``diarize.py`` so the Swift side reuses the same
  decoder logic; ``start``/``end`` are recording-absolute (window-relative
  pyannote times plus ``window_start``).

* The labels (``SPEAKER_00`` …) are **per-window** and not stable across
  windows — online diarization spawns labels freely. Stitching them into stable
  provisional ``Them``/``Them #N`` IDs is the Swift side's job
  (``LiveDiarizer``), by matching each window's embeddings against the running
  set of live speakers. The post-pass corrects everything anyway.

Once the model is loaded the process emits a readiness line carrying the
model checkpoint's HF commit SHA::

    {"ready": true, "model_revision": "<HF hub commit SHA>"}

The Swift side keys its read-only speaker-library lookup (R18) on that
revision so it never matches a centroid across a pyannote model change.

The model is loaded once via :func:`pulsartrace_ai.diarize.load_pipeline`, so
the HF cache redirect and the telemetry kill-switch (D12) are inherited.

stdin EOF (the engine closes the pipe) ends the loop and the process exits 0.
"""

from __future__ import annotations

import json
import os

# Telemetry kill-switch must run before pyannote is imported — same rationale
# as diarize.py (Hard Invariant #1 / DECISIONS.md D12).
os.environ["PYANNOTE_METRICS_ENABLED"] = "false"

import sys
import time
import wave
from pathlib import Path
from typing import Any

from pulsartrace_ai.diarize import (
    DiarizationError,
    Span,
    _annotation_to_spans,
    _model_revision,
    _seed_everything,
    load_pipeline,
)


def _wav_duration_seconds(wav_path: Path) -> float:
    with wave.open(str(wav_path), "rb") as w:
        rate = w.getframerate()
        if rate <= 0:
            raise DiarizationError(f"WAV has invalid sample rate: {wav_path.name}")
        return w.getnframes() / float(rate)


def diarize_window(
    window_wav: Path,
    window_start: float,
    pipeline: "pyannote.audio.Pipeline",
) -> dict[str, Any]:
    """Diarize one window WAV; return the response dict (recording-absolute).

    Provisional and best-effort: a window with a single speaker yields one
    label, a window with none yields empty lists. Errors are surfaced to the
    caller rather than crashing the long-lived loop.

    RNG determinism note (R16): :func:`main` calls
    :func:`pulsartrace_ai.diarize._seed_everything` **once per subprocess**,
    before the loop. RNG state is therefore *seeded once and shared across
    every window* — it is **not** re-seeded per call. So the offline
    determinism guarantee (a fixed WAV → byte-identical output) does **not**
    hold per-window here: window N's result depends on the RNG state left by
    windows 1..N-1. This is intentional — the live pass is explicitly
    best-effort and provisional (R16); the offline post-pass, which does seed
    per run, is the source of truth.
    """
    if not window_wav.is_file():
        raise DiarizationError(f"window WAV not found: {window_wav.name}")

    # Time the pyannote inference itself — neural VAD + embedding + clustering
    # over the window. This is the dominant cost of the live pass; everything
    # the Swift side does around it (WAV write, IPC, stitching) is negligible
    # by comparison. Reported as `infer_ms` (numbers only — never content,
    # Hard Invariant #7) so the Swift side can log per-window timing and the
    # timing test can assert it stays within the window timeout.
    started = time.monotonic()
    output = pipeline(str(window_wav))
    infer_ms = round((time.monotonic() - started) * 1000.0, 1)
    diarization = output.speaker_diarization
    raw_embeddings = output.speaker_embeddings

    speakers = sorted(str(label) for label in diarization.labels())

    # Shift window-relative pyannote times to recording-absolute.
    spans = [
        Span(speaker=s.speaker, start=s.start + window_start, end=s.end + window_start)
        for s in _annotation_to_spans(diarization)
    ]

    embeddings: dict[str, list[float]] = {}
    embedding_dim = 0
    if raw_embeddings is not None and len(raw_embeddings) > 0:
        embedding_dim = int(raw_embeddings.shape[1])
        for index, label in enumerate(speakers):
            if index < len(raw_embeddings):
                embeddings[label] = [float(x) for x in raw_embeddings[index]]

    print(
        f"[live_diarize] window @{window_start:.1f}s diarized in "
        f"{infer_ms:.0f}ms ({len(speakers)} speaker(s))",
        file=sys.stderr,
    )

    return {
        "window_start": round(window_start, 3),
        "speakers": speakers,
        "spans": [s.as_dict() for s in spans],
        "embeddings": embeddings,
        "embedding_dim": embedding_dim,
        "infer_ms": infer_ms,
    }


def main(argv: list[str] | None = None) -> int:
    """Long-lived live-diarization loop: read request lines, emit response lines.

    Loads the pyannote pipeline once, then services one window per stdin line
    until EOF. Diagnostics go to stderr (the Swift parent pipes them into the
    operational log tagged ``[python]``). A per-window failure emits a response
    line with an ``error`` field rather than aborting the loop, so one bad
    window does not end the whole live pass.
    """
    _seed_everything()
    try:
        pipeline = load_pipeline()
    except Exception as exc:  # noqa: BLE001 — a load failure is fatal
        print(f"[live_diarize] pipeline load failed: {exc!r}", file=sys.stderr)
        return 1

    # Signal readiness so the Swift side knows the model is loaded and it may
    # start sending windows. The ready line carries `model_revision` — the HF
    # commit SHA of the model checkpoint — so the Swift side can scope a
    # read-only speaker-library lookup to the matching pyannote model (R18 /
    # Open Question #3). Resolved offline-first from the cached snapshot.
    sys.stdout.write(
        json.dumps({"ready": True, "model_revision": _model_revision()}) + "\n"
    )
    sys.stdout.flush()
    print("[live_diarize] ready — pipeline loaded", file=sys.stderr)

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            window_wav = Path(request["window_wav"])
            window_start = float(request.get("window_start", 0.0))
            response = diarize_window(window_wav, window_start, pipeline)
            # allow_nan=False so a NaN/Inf embedding raises a clean ValueError
            # here rather than emitting non-standard JSON tokens Swift's
            # decoder silently rejects (matches diarize.py). Serializing inside
            # the try means a NaN window degrades to an `error` response
            # rather than killing the long-lived loop.
            line_out = json.dumps(
                response, separators=(",", ":"), allow_nan=False
            )
        except Exception as exc:  # noqa: BLE001 — keep the loop alive
            print(f"[live_diarize] window failed: {exc!r}", file=sys.stderr)
            line_out = json.dumps({"error": str(exc)}, separators=(",", ":"))
        sys.stdout.write(line_out + "\n")
        sys.stdout.flush()

    print("[live_diarize] stdin closed — exiting", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
