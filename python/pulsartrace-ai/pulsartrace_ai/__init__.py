"""PulsarTrace AI layer.

A captive Python subprocess that runs pyannote (offline diarization) and diart
(live diarization). The Swift engine spawns it and exchanges speaker spans and
embeddings over the IPC boundary. The real diarization code lands in Epic 3;
Epic 1 ships only the package skeleton.
"""

__version__ = "0.1.0"
