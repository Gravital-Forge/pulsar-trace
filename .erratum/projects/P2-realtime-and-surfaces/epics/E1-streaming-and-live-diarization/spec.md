# PT-P2-E1 · Streaming & Live Diarization — Specification

**Status:** Frozen · **Opened:** 2026-05-16 · **Closed:** 2026-05-16

## Intent

Add the live pass: streaming transcription that grows an append-only live transcript (PT-P2-R1),
windowed live diarization with provisional, library-aware labels (PT-P2-R2), and microphone-echo
dedup (PT-P2-R3). Consumes the audio sources (PT-C1) and reads the speaker library (PT-C5)
read-only; extends the Transcript Output contract (PT-C11) with the provisional live stream.

## Acceptance criteria

- A real-time-paced fixture grows the live transcript monotonically, with bounded lag and no revised
  word.
- Live speakers carry provisional labels, stitched across windows; a known speaker shows their name,
  still provisional; the library is never written.
- Speech captured on both mic and system appears once.

## Tasks

- PT-P2-E1-T1 — Anchored-window streaming transcriber + agreement committer
- PT-P2-E1-T2 — Append-only live markdown writer (session-start marker + header)
- PT-P2-E1-T3 — Windowed live diarizer with cross-window embedding stitch + read-only library lookup
- PT-P2-E1-T4 — Microphone-echo dedup
- PT-P2-E1-T5 — `--live` engine mode writing the system WAV for later refine
