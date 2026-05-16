"""Shared pytest fixtures for the PulsarTrace AI layer (Epic 3).

The diarization tests run **real pyannote** on the committed audio fixtures —
this is where pyannote correctness is verified (the Swift Pipeline tests use a
pre-generated JSON fixture so they stay fast; see the epic plan).

Loading the pyannote pipeline costs ~10–30s, so it is loaded **once** per test
session (`session`-scoped fixture) and shared across every diarization test.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

# Repo layout: python/pulsartrace-ai/tests/conftest.py → repo root is 3 up.
REPO_ROOT = Path(__file__).resolve().parents[3]

# Committed audio fixtures (PRD §12, DECISIONS.md D6 — capitalized `Tests/`).
AUDIO_FIXTURES = REPO_ROOT / "Tests" / "Fixtures" / "audio"


def _load_dotenv() -> None:
    """Load HF_TOKEN from the repo `.env` if it is not already in the env.

    pyannote community-1 is a gated model; the token is needed to download it.
    Production (Epic 10) moves the token to the macOS Keychain — this dev-only
    `.env` fallback is documented in DECISIONS.md D9/D10.
    """
    if os.environ.get("HF_TOKEN"):
        return
    env_file = REPO_ROOT / ".env"
    if not env_file.is_file():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


@pytest.fixture(scope="session")
def audio_dir() -> Path:
    """Directory holding the committed audio fixtures."""
    assert AUDIO_FIXTURES.is_dir(), f"missing audio fixtures: {AUDIO_FIXTURES}"
    return AUDIO_FIXTURES


@pytest.fixture
def require_hf_token() -> None:
    """Skip a test cleanly when no HF token is available.

    The live-diarize *subprocess* tests spawn the real `pulsartrace_ai.live_diarize`
    process, which loads the gated pyannote community-1 model. Without a token
    the subprocess fails its model load and the test sees a confusing
    `JSONDecodeError` on the missing ready line. This guard — the same pattern
    as `diarization_pipeline` — turns that into a clean skip.
    """
    _load_dotenv()
    if not os.environ.get("HF_TOKEN"):
        pytest.skip("HF_TOKEN not set — pyannote community-1 is gated")


@pytest.fixture(scope="session")
def diarization_pipeline():
    """A loaded pyannote pipeline, shared across the whole test session.

    Skips the suite cleanly if no HF token is available, so a developer who
    has not configured one still gets a green (skipped) run rather than a
    download failure.
    """
    _load_dotenv()
    if not os.environ.get("HF_TOKEN"):
        pytest.skip("HF_TOKEN not set — pyannote community-1 is gated")

    from pulsartrace_ai.diarize import load_pipeline

    return load_pipeline()
