"""Real-pyannote tests for the live (windowed) diarization layer (Epic 6).

`pulsartrace_ai.live_diarize` is the captive subprocess the Swift `LiveDiarizer`
drives for the live pass. These run the actual pyannote pipeline on a window of
a committed audio fixture and verify the windowed entry point + the long-lived
subprocess protocol.

The pipeline is loaded once per session (see `conftest.diarization_pipeline`)
and reused; the subprocess-protocol test pays its own model load.
"""

from __future__ import annotations

import json
import subprocess
import sys
import wave

import pytest

from pulsartrace_ai.live_diarize import diarize_window


def _window_wav(src_wav, dst_wav, start_s, end_s):
    """Write `[start_s, end_s)` of `src_wav` to `dst_wav` (a window slice)."""
    with wave.open(str(src_wav), "rb") as r:
        rate = r.getframerate()
        r.setpos(int(start_s * rate))
        frames = r.readframes(int((end_s - start_s) * rate))
        with wave.open(str(dst_wav), "wb") as w:
            w.setnchannels(r.getnchannels())
            w.setsampwidth(r.getsampwidth())
            w.setframerate(rate)
            w.writeframes(frames)


def test_diarize_window_returns_recording_absolute_spans(
    audio_dir, diarization_pipeline, tmp_path
):
    """A window of the two-speaker fixture diarizes; spans are recording-absolute."""
    window = tmp_path / "win.wav"
    # A 10s window starting 4s into the recording.
    _window_wav(audio_dir / "two-speakers-alternating.wav", window, 4.0, 14.0)

    result = diarize_window(window, window_start=4.0, pipeline=diarization_pipeline)

    assert "speakers" in result and "spans" in result
    assert result["embedding_dim"] in (0, 256)
    # Spans are shifted by window_start → recording-absolute, never before 4s.
    for span in result["spans"]:
        assert span["start"] >= 4.0 - 0.01
        assert span["end"] > span["start"]
    # Each speaker label has an embedding entry (used for live stitching).
    for speaker in result["speakers"]:
        assert speaker in result["embeddings"]


def test_live_diarize_subprocess_protocol(audio_dir, tmp_path, require_hf_token):
    """The long-lived subprocess: ready handshake, one window in → one JSON out."""
    window = tmp_path / "win.wav"
    _window_wav(audio_dir / "two-speakers-alternating.wav", window, 0.0, 10.0)

    proc = subprocess.Popen(
        [sys.executable, "-m", "pulsartrace_ai.live_diarize"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        # First stdout line is the readiness handshake (model loaded).
        ready_line = proc.stdout.readline()
        assert json.loads(ready_line).get("ready") is True

        # Send one window request; read one response line.
        request = json.dumps({"window_wav": str(window), "window_start": 0.0})
        proc.stdin.write(request + "\n")
        proc.stdin.flush()
        response = json.loads(proc.stdout.readline())

        assert "spans" in response
        assert "embeddings" in response
        assert "error" not in response
    finally:
        # Closing stdin makes the loop hit EOF and exit 0.
        proc.stdin.close()
        proc.wait(timeout=30)

    assert proc.returncode == 0


def test_live_diarize_bad_window_does_not_crash_loop(
    audio_dir, tmp_path, require_hf_token
):
    """A bad window request yields an `error` response, not a crashed loop."""
    good_window = tmp_path / "win.wav"
    _window_wav(audio_dir / "two-speakers-alternating.wav", good_window, 0.0, 8.0)

    proc = subprocess.Popen(
        [sys.executable, "-m", "pulsartrace_ai.live_diarize"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert json.loads(proc.stdout.readline()).get("ready") is True

        # A window pointing at a non-existent WAV → error response.
        proc.stdin.write(
            json.dumps({"window_wav": "/no/such/file.wav", "window_start": 0.0})
            + "\n"
        )
        proc.stdin.flush()
        bad = json.loads(proc.stdout.readline())
        assert "error" in bad

        # The loop is still alive — a good window after a bad one still works.
        proc.stdin.write(
            json.dumps({"window_wav": str(good_window), "window_start": 0.0}) + "\n"
        )
        proc.stdin.flush()
        good = json.loads(proc.stdout.readline())
        assert "error" not in good
        assert "spans" in good
    finally:
        proc.stdin.close()
        proc.wait(timeout=30)

    assert proc.returncode == 0
