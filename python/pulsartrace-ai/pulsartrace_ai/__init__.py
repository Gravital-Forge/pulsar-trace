"""PulsarTrace AI layer.

A captive Python subprocess that runs pyannote (offline diarization and
windowed live diarization). The Swift engine spawns it and exchanges speaker
spans and embeddings over the IPC boundary. Offline diarization lands in
Epic 3; the windowed live pass (DECISIONS.md D19 — windowed-pyannote, not
diart) lands in Epic 6.
"""

__version__ = "0.1.0"
