"""Real-pyannote diarization tests for the PulsarTrace AI layer (R67).

These run the actual ``pyannote/speaker-diarization-community-1`` pipeline on
the committed audio fixtures. They are the project's verification that the
Python diarization layer is correct — the Swift Pipeline tests deliberately
consume a pre-generated JSON fixture instead of paying the model-load cost on
every run.

The pipeline is loaded once per session (see ``conftest.diarization_pipeline``)
and reused across every case here.
"""

from __future__ import annotations

import json
import math
import subprocess
import sys

import numpy as np
import pytest

from pulsartrace_ai._common import _embeddings_by_label
from pulsartrace_ai.diarize import (
    MODEL_ID,
    SCHEMA_VERSION,
    DiarizationError,
    DiarizationResult,
    Span,
    diarize,
)


def test_two_speakers_alternating(audio_dir, diarization_pipeline):
    """Alternating two-speaker fixture → exactly 2 speakers, sane spans."""
    result = diarize(
        audio_dir / "two-speakers-alternating.wav", pipeline=diarization_pipeline
    )

    assert result.speakers == ["SPEAKER_00", "SPEAKER_01"]
    assert len(result.spans) >= 2
    # Spans are time-ordered and non-degenerate.
    for span in result.spans:
        assert span.end > span.start
    starts = [s.start for s in result.spans]
    assert starts == sorted(starts)
    # Both speakers are attributed at least one span.
    attributed = {s.speaker for s in result.spans}
    assert attributed == {"SPEAKER_00", "SPEAKER_01"}


def test_two_speakers_overlap_surfaces_both(audio_dir, diarization_pipeline):
    """Overlapping speech: both attributions appear (edge case).

    ``spans`` preserves overlap — there must exist a moment where two
    different speakers' spans overlap in time.
    """
    result = diarize(
        audio_dir / "two-speakers-overlap.wav", pipeline=diarization_pipeline
    )

    assert len(result.speakers) == 2

    overlap_found = False
    for i, a in enumerate(result.spans):
        for b in result.spans[i + 1 :]:
            if a.speaker == b.speaker:
                continue
            if min(a.end, b.end) > max(a.start, b.start):
                overlap_found = True
    assert overlap_found, "overlap fixture must yield overlapping speaker spans"

    # exclusive_spans is the overlap-resolved variant: never two speakers at
    # the same instant.
    for i, a in enumerate(result.exclusive_spans):
        for b in result.exclusive_spans[i + 1 :]:
            assert min(a.end, b.end) <= max(a.start, b.start), (
                "exclusive_spans must not have two speakers active at once"
            )


def test_single_speaker_no_ghost_speakers(audio_dir, diarization_pipeline):
    """Single-speaker recording → exactly 1 speaker, no ghosts (edge case)."""
    result = diarize(
        audio_dir / "single-speaker-30s.wav", pipeline=diarization_pipeline
    )

    assert result.speakers == ["SPEAKER_00"]
    assert len(result.spans) >= 1
    assert all(s.speaker == "SPEAKER_00" for s in result.spans)
    # Exactly one embedding for the one speaker.
    assert set(result.embeddings) == {"SPEAKER_00"}


def test_system_stream_fixture_diarizes(audio_dir, diarization_pipeline):
    """The paired-recording system stream diarizes (R17: only system stream).

    The mic stream is never handed to this layer; only ``system.wav`` is.
    """
    result = diarize(
        audio_dir / "mic-and-system-paired" / "system.wav",
        pipeline=diarization_pipeline,
    )
    assert len(result.speakers) >= 1


def test_embeddings_have_correct_dimension(audio_dir, diarization_pipeline):
    """R29: per-speaker embeddings come from pyannote's own embedding model,
    fixed 256-d vectors."""
    result = diarize(
        audio_dir / "two-speakers-alternating.wav", pipeline=diarization_pipeline
    )

    assert result.embedding_dim == 256
    assert set(result.embeddings) == set(result.speakers)
    for speaker, vector in result.embeddings.items():
        assert len(vector) == 256, f"{speaker} embedding is not 256-d"
        assert all(isinstance(x, float) for x in vector)


def test_result_carries_model_identity(audio_dir, diarization_pipeline):
    """Model identity is in the output (Open Question #3).

    The speaker library keys centroids off the model checkpoint's HF commit
    SHA (``model_revision``) so it can refuse to match embeddings across a
    model change; the pyannote.audio library version is carried as a
    secondary identity field.
    """
    result = diarize(
        audio_dir / "single-speaker-30s.wav", pipeline=diarization_pipeline
    )
    assert result.model_version  # non-empty pyannote.audio library version
    assert result.model_revision  # non-empty HF checkpoint commit SHA
    payload = result.as_dict()
    assert payload["model"] == MODEL_ID
    assert payload["schema"] == SCHEMA_VERSION
    assert payload["model_version"] == result.model_version
    assert payload["model_revision"] == result.model_revision


def test_diarize_is_deterministic(audio_dir, diarization_pipeline):
    """Seeded RNGs → byte-identical JSON across runs (PRD §12)."""
    wav = audio_dir / "two-speakers-alternating.wav"
    first = json.dumps(diarize(wav, pipeline=diarization_pipeline).as_dict(), sort_keys=True)
    second = json.dumps(diarize(wav, pipeline=diarization_pipeline).as_dict(), sort_keys=True)
    assert first == second


def test_missing_file_raises_clean_error(diarization_pipeline):
    """A missing WAV fails with a clean DiarizationError, not a crash."""
    with pytest.raises(DiarizationError, match="not found"):
        diarize("/nonexistent/path/to/audio.wav", pipeline=diarization_pipeline)


def test_telemetry_is_disabled(audio_dir, diarization_pipeline):
    """Hard Invariant #1: pyannote's OpenTelemetry phone-home is OFF.

    `diarize` sets `PYANNOTE_METRICS_ENABLED=false` before importing pyannote
    and calls `set_telemetry_metrics(False)`. Verify the metrics gate reads
    disabled, so `track_pipeline_apply` records nothing and the OTLP exporter
    has nothing to send.
    """
    import os

    assert os.environ.get("PYANNOTE_METRICS_ENABLED") == "false"

    from pyannote.audio.telemetry.metrics import is_metrics_enabled

    assert is_metrics_enabled() is False

    # Running a real diarization must not flip the gate back on.
    diarize(audio_dir / "single-speaker-30s.wav", pipeline=diarization_pipeline)
    assert is_metrics_enabled() is False


def _result_like_diarize(
    speakers: list[str],
    spans: list[Span],
    raw_embeddings,
) -> DiarizationResult:
    """Build a DiarizationResult exactly the way `diarize()` does post-pipeline.

    Uses the same `_embeddings_by_label` mapping `diarize()` calls, so these
    tests exercise the real construction path without paying a model load.
    """
    embeddings, embedding_dim, _ = _embeddings_by_label(raw_embeddings, speakers)
    return DiarizationResult(
        model_revision="0000000000000000000000000000000000000000",
        model_version="4.0.4",
        audio_duration=37.0,
        speakers=speakers,
        spans=spans,
        exclusive_spans=spans,
        embeddings=embeddings,
        embedding_dim=embedding_dim,
    )


def test_nan_embedding_row_is_dropped_and_result_serializes() -> None:
    """Regression: a near-silent recording made pyannote emit a NaN embedding
    row, and `json.dump(..., allow_nan=False)` raised ValueError — failing the
    refinement job as `diarizeCrashed` on every retry. The NaN row is now
    dropped at the source; the speaker keeps its spans and its label."""
    speakers = ["SPEAKER_00", "SPEAKER_01"]
    spans = [
        Span(speaker="SPEAKER_00", start=0.5, end=2.1),
        Span(speaker="SPEAKER_01", start=3.0, end=3.4),
    ]
    raw = np.array([[0.1] * 256, [math.nan] * 256])

    result = _result_like_diarize(speakers, spans, raw)

    # The dump that crashed in production must now succeed.
    payload = json.loads(json.dumps(result.as_dict(), allow_nan=False))

    # The NaN speaker keeps its label and spans — only the embedding is gone.
    assert payload["speakers"] == ["SPEAKER_00", "SPEAKER_01"]
    assert any(s["speaker"] == "SPEAKER_01" for s in payload["spans"])
    assert set(payload["embeddings"]) == {"SPEAKER_00"}
    assert payload["embedding_dim"] == 256


def test_main_emits_nothing_on_stdout_when_serialization_fails(
    monkeypatch, capsys
) -> None:
    """Regression: `json.dump` used to stream a partial JSON object to stdout
    before raising on a non-finite value, and the exception escaped `main()`'s
    try/except (exit 1, partial stdout). Serialization now happens inside the
    try, before any stdout write: a failure is a clean exit 2 with an empty
    stdout — never partial JSON for the Swift parent to choke on."""
    import pulsartrace_ai.diarize as diarize_module

    class _Unserializable:
        def as_dict(self):
            return {"embeddings": {"SPEAKER_00": [math.nan]}}

    monkeypatch.setattr(diarize_module, "diarize", lambda wav: _Unserializable())

    exit_code = diarize_module.main(["unused.wav"])

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert "[diarize] unexpected failure" in captured.err


def test_main_writes_exactly_one_json_line_on_success(monkeypatch, capsys) -> None:
    """The atomic write: stdout receives the full payload as one line."""
    import pulsartrace_ai.diarize as diarize_module

    result = _result_like_diarize(
        ["SPEAKER_00"],
        [Span(speaker="SPEAKER_00", start=0.0, end=1.6)],
        np.array([[0.25] * 8]),
    )
    monkeypatch.setattr(diarize_module, "diarize", lambda wav: result)

    exit_code = diarize_module.main(["unused.wav"])

    captured = capsys.readouterr()
    assert exit_code == 0
    assert captured.out.count("\n") == 1
    assert captured.out.endswith("\n")
    assert json.loads(captured.out) == result.as_dict()
    assert "[diarize] ok" in captured.err


def test_cli_end_to_end(audio_dir):
    """E2E: run the module as a subprocess and validate the JSON contract.

    This is the one case that exercises the real Swift↔Python boundary shape —
    `python -m pulsartrace_ai.diarize <wav>` → JSON on stdout, diagnostics on
    stderr. It loads the model fresh (no shared pipeline), so it is the slow
    case in this suite; it is kept to a single fixture deliberately.
    """
    wav = audio_dir / "two-speakers-alternating.wav"
    proc = subprocess.run(
        [sys.executable, "-m", "pulsartrace_ai.diarize", str(wav)],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert proc.returncode == 0, f"subprocess failed: {proc.stderr}"

    payload = json.loads(proc.stdout)
    # JSON contract the Swift Diarizer decodes.
    assert payload["schema"] == SCHEMA_VERSION
    assert payload["model"] == MODEL_ID
    assert payload["model_version"]
    assert payload["model_revision"]
    assert payload["embedding_dim"] == 256
    assert len(payload["speakers"]) == 2
    assert payload["spans"], "spans must be non-empty"
    for span in payload["spans"]:
        assert {"speaker", "start", "end"} <= set(span)
    for speaker, vector in payload["embeddings"].items():
        assert len(vector) == 256

    # Diagnostics go to stderr (the Swift parent tags them [python], R60).
    assert "[diarize]" in proc.stderr
