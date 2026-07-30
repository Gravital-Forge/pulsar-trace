#!/usr/bin/env python3
"""Mint Tests/Fixtures/audio/mic-two-speakers.wav (PT-P8-E4-T4).

A two-voice mic fixture composited from existing committed fixtures with only
the Python standard library (`wave`) — no new tool dependency (afconvert/sox
cannot concatenate, and this repo pins no audio-processing package).

Composition: `single-speaker-30s.wav` (ElevenLabs voice A, ~30 s) followed by
`two-speakers-alternating.wav` (voices A + B, ~24 s). Real FluidAudio
diarization of the result yields two mic clusters — voice A dominant (so the
E3 owner-profile seed, derived from the fixture's own dominant embedding,
attributes it to `You`) plus voice B present as the guest. All sources are
16 kHz mono Int16 WAV, so the concatenation is a straight PCM-frame append with
one rebuilt header.
"""
import wave
from pathlib import Path

AUDIO = Path(__file__).resolve().parent.parent / "Tests" / "Fixtures" / "audio"
PARTS = ["single-speaker-30s.wav", "two-speakers-alternating.wav"]
OUT = AUDIO / "mic-two-speakers.wav"


def main() -> None:
    params = None
    frames = bytearray()
    for name in PARTS:
        with wave.open(str(AUDIO / name), "rb") as w:
            p = w.getparams()
            if params is None:
                params = p
            else:
                assert (p.nchannels, p.framerate, p.sampwidth) == (
                    params.nchannels,
                    params.framerate,
                    params.sampwidth,
                ), f"{name} format mismatch: {p} vs {params}"
            frames += w.readframes(w.getnframes())

    assert params is not None
    with wave.open(str(OUT), "wb") as out:
        out.setnchannels(params.nchannels)
        out.setsampwidth(params.sampwidth)
        out.setframerate(params.framerate)
        out.writeframes(bytes(frames))
    print(f"wrote {OUT} ({len(frames)} PCM bytes, "
          f"{len(frames) // (params.sampwidth * params.nchannels)} frames)")


if __name__ == "__main__":
    main()
