"""PulsarTrace AI layer.

A captive Python subprocess that runs pyannote (offline diarization and
windowed live diarization). The Swift engine spawns it and exchanges speaker
spans and embeddings over the IPC boundary. The windowed live pass uses
windowed-pyannote, not diart (DECISIONS.md D19).
"""

__version__ = "0.1.0"
