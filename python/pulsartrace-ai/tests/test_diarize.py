"""Real-pyannote diarization tests for the PulsarTrace AI layer (Epic 3, R67).

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
import subprocess
import sys

import pytest

from pulsartrace_ai.diarize import (
    MODEL_ID,
    SCHEMA_VERSION,
    DiarizationError,
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
    """Overlapping speech: both attributions appear (Epic 3 edge case).

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
    """Single-speaker recording → exactly 1 speaker, no ghosts (Epic 3 edge)."""
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

    Epic 5's speaker library keys centroids off the model checkpoint's HF
    commit SHA (``model_revision``) so it can refuse to match embeddings
    across a model change; the pyannote.audio library version is carried as a
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
