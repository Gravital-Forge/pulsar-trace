"""Unit tests for `pulsartrace_ai._common` helpers.

`_embeddings_by_label` is the shared label→embedding mapping used by both the
offline (`diarize`) and live (`live_diarize`) entry points. Its non-finite
filter is the fix for a production crash: a near-silent recording made
pyannote emit a NaN embedding row (a cluster with no usable speech frames),
which `json.dump(..., allow_nan=False)` rejected — failing the refinement job
as `diarizeCrashed` on every retry, and killing live windows independently.

These tests are pure numpy — no pyannote model load, no fixtures.
"""

from __future__ import annotations

import math

import numpy as np

from pulsartrace_ai._common import _embeddings_by_label


def test_finite_rows_map_labels_to_rows_in_order() -> None:
    """Each sorted label gets its aligned row; values become Python floats."""
    raw = np.array([[0.1, 0.2, 0.3], [-0.4, 0.5, -0.6]])
    embeddings, dim, dropped = _embeddings_by_label(raw, ["SPEAKER_00", "SPEAKER_01"])

    assert list(embeddings) == ["SPEAKER_00", "SPEAKER_01"]
    assert embeddings["SPEAKER_00"] == [0.1, 0.2, 0.3]
    assert embeddings["SPEAKER_01"] == [-0.4, 0.5, -0.6]
    assert all(
        isinstance(x, float) for row in embeddings.values() for x in row
    )
    assert dim == 3
    assert dropped == []


def test_nan_row_is_dropped_and_reported_others_kept() -> None:
    """A NaN-containing row is dropped; its label is reported; others survive."""
    raw = np.array([[0.1, 0.2], [math.nan, 0.5], [0.7, 0.8]])
    embeddings, dim, dropped = _embeddings_by_label(
        raw, ["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]
    )

    assert set(embeddings) == {"SPEAKER_00", "SPEAKER_02"}
    assert dim == 2
    assert dropped == ["SPEAKER_01"]


def test_inf_row_is_dropped_and_reported() -> None:
    """Infinity is just as non-finite as NaN — same drop path."""
    raw = np.array([[0.1, 0.2], [math.inf, 0.5]])
    embeddings, dim, dropped = _embeddings_by_label(raw, ["SPEAKER_00", "SPEAKER_01"])

    assert set(embeddings) == {"SPEAKER_00"}
    assert dim == 2
    assert dropped == ["SPEAKER_01"]


def test_all_rows_non_finite_keeps_dim_and_reports_all_labels() -> None:
    """Everything dropped → empty dict, but dim still comes from the shape.

    The near-silent-recording case: every cluster can lack usable speech
    frames. `embedding_dim` stays truthful to what pyannote emitted.
    """
    raw = np.array([[math.nan, math.nan], [-math.inf, 0.5]])
    embeddings, dim, dropped = _embeddings_by_label(raw, ["SPEAKER_00", "SPEAKER_01"])

    assert embeddings == {}
    assert dim == 2
    assert dropped == ["SPEAKER_00", "SPEAKER_01"]


def test_none_embeddings_yield_empty_result() -> None:
    """pyannote can return no embeddings at all (None) → empty everything."""
    assert _embeddings_by_label(None, ["SPEAKER_00"]) == ({}, 0, [])


def test_empty_embeddings_yield_empty_result() -> None:
    """A zero-row array behaves like None (no shape[1] poked)."""
    raw = np.empty((0, 256))
    assert _embeddings_by_label(raw, ["SPEAKER_00"]) == ({}, 0, [])


def test_more_speakers_than_rows_leaves_extras_absent() -> None:
    """Labels beyond the row count are simply absent — not dropped, not erred.

    Preserves the pre-fix behavior: the Swift reconciler already tolerates a
    span label with no embedding entry.
    """
    raw = np.array([[0.1, 0.2]])
    embeddings, dim, dropped = _embeddings_by_label(
        raw, ["SPEAKER_00", "SPEAKER_01"]
    )

    assert set(embeddings) == {"SPEAKER_00"}
    assert dim == 2
    assert dropped == []
