"""Real-pyannote tests for the live (windowed) diarization layer.

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


# Mirrors `LiveDiarizer.Configuration.windowTimeout` (LiveDiarizer.swift): a
# window whose pyannote inference overruns this is given up on by the Swift
# side and the live pass degrades. Staying within it is the live pass's core
# timing contract — so it is the non-flaky ceiling this test asserts.
WINDOW_TIMEOUT_MS = 30_000


def test_diarize_window_inference_stays_within_window_timeout(
    audio_dir, diarization_pipeline, tmp_path
):
    """A 10s window's pyannote inference completes within the window timeout.

    `diarize_window` reports `infer_ms` — the wall time of the pyannote call,
    which dominates live-diarization cost (WAV write, IPC and Swift-side
    stitching around it are negligible). The live pass steps windows every ~5s
    and drops any window that overruns `windowTimeout` (30s); this test guards
    that contract.

    The asserted threshold is the timeout itself — a hard ceiling that does not
    flake on slow CI (CPU-only Tart VMs / EC2 Macs without MPS). The actual
    figure is printed unconditionally so the real per-window cost is visible:
    on Apple-Silicon MPS a 10s window measures ~0.5-0.7s — two orders of
    magnitude inside the ~5s window step, so the diarizer never falls behind.
    """
    window = tmp_path / "win.wav"
    # A 10s window — the live pass's default `diarizationWindow`.
    _window_wav(audio_dir / "two-speakers-alternating.wav", window, 4.0, 14.0)

    result = diarize_window(window, window_start=4.0, pipeline=diarization_pipeline)

    infer_ms = result["infer_ms"]
    print(f"\n[timing] 10s live-diarization window: pyannote infer {infer_ms:.0f} ms")

    assert infer_ms > 0
    assert infer_ms < WINDOW_TIMEOUT_MS, (
        f"window inference {infer_ms:.0f}ms exceeds the {WINDOW_TIMEOUT_MS}ms "
        "live-pass window timeout — windows would be dropped"
    )


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
