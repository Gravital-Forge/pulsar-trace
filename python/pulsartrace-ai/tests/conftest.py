"""Shared pytest fixtures for the PulsarTrace AI layer.

The diarization tests run **real pyannote** on the committed audio fixtures —
this is where pyannote correctness is verified (the Swift Pipeline tests use a
pre-generated JSON fixture so they stay fast).

Loading the pyannote pipeline costs ~10-30s, so it is loaded **once** per test
session (`session`-scoped fixture) and shared across every diarization test.

## Offline by design — so the suite runs inside the sandbox

pyannote's ``Pipeline.from_pretrained`` normally makes a Hugging Face Hub call.
Inside the Claude Code Bash sandbox the only network egress is a SOCKS proxy
huggingface_hub's httpx client cannot use, so the suite historically had to run
unsandboxed. Instead, :func:`_configure_offline_hf` (run at import, before any
``huggingface_hub`` import) points HF at PulsarTrace's own model cache and
forces offline mode: a cached model loads with **zero network**, so the suite
runs anywhere — including sandboxed.

The cache is populated once by ``python/prefetch-model.sh`` (``build-venv.sh``
runs it as its final step). A test that needs the model skips cleanly, naming
that script, when the cache is empty.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

# Repo layout: python/pulsartrace-ai/tests/conftest.py → repo root is 3 up.
REPO_ROOT = Path(__file__).resolve().parents[3]

# Committed audio fixtures (PRD §12, DECISIONS.md D6 — capitalized `Tests/`).
AUDIO_FIXTURES = REPO_ROOT / "Tests" / "Fixtures" / "audio"

# PulsarTrace's own Hugging Face cache (DECISIONS.md D10). Must mirror
# `pulsartrace_ai.diarize.default_cache_dir()` — duplicated here because it has
# to be known *before* `pulsartrace_ai` (hence huggingface_hub) is imported.
HF_CACHE_DIR = Path.home() / "Library" / "Caches" / "PulsarTrace" / "huggingface"

_PREFETCH_HINT = (
    "pyannote diarization model is not in the local cache — run "
    "`python/prefetch-model.sh` once (online, with HF_TOKEN) to populate it"
)


def _configure_offline_hf() -> None:
    """Make pyannote / huggingface_hub load the model offline from the cache.

    Runs at conftest import — before test collection imports ``pulsartrace_ai``
    and thus before any ``huggingface_hub`` import resolves these settings.

    * ``HF_HOME`` → PulsarTrace's cache, so the model prefetched by
      ``python/prefetch-model.sh`` is found. Set unconditionally — never defer
      to an ambient ``HF_HOME``, which could point at a different cache holding
      a different model revision and silently green a run against it.
    * ``HF_HUB_OFFLINE=1`` → no Hub lookups; a cached model loads with no
      socket opened.
    * The sandbox's proxy vars are dropped so httpx never tries to build a
      SOCKS transport (which would need the ``socksio`` package). Offline mode
      means no connection is attempted anyway — this just keeps the transport
      construction from failing first.
    """
    os.environ["HF_HOME"] = str(HF_CACHE_DIR)
    os.environ["HF_HUB_OFFLINE"] = "1"
    for proxy_var in (
        "ALL_PROXY", "all_proxy",
        "HTTP_PROXY", "http_proxy",
        "HTTPS_PROXY", "https_proxy",
    ):
        os.environ.pop(proxy_var, None)


_configure_offline_hf()


def _diarization_model_cached() -> bool:
    """True when the pyannote community-1 model is in the local HF cache."""
    snapshots = (
        Path(os.environ["HF_HOME"])
        / "hub"
        / "models--pyannote--speaker-diarization-community-1"
        / "snapshots"
    )
    return snapshots.is_dir() and any(snapshots.iterdir())


def _load_dotenv() -> None:
    """Load HF_TOKEN from the repo `.env` if it is not already in the env.

    pyannote community-1 is a gated model; the token is needed to download it.
    Production moves the token to the macOS Keychain — this dev-only `.env`
    fallback is documented in DECISIONS.md D9/D10.
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
    """Skip a test cleanly when the diarization model cannot be loaded offline.

    The live-diarize *subprocess* tests spawn the real `pulsartrace_ai.live_diarize`
    process, which loads the gated pyannote community-1 model from the local
    cache. Skip — rather than fail confusingly on the missing ready line — when
    either the gating token or the prefetched model is absent.
    """
    _load_dotenv()
    if not os.environ.get("HF_TOKEN"):
        pytest.skip("HF_TOKEN not set — pyannote community-1 is gated")
    if not _diarization_model_cached():
        pytest.skip(_PREFETCH_HINT)


@pytest.fixture(scope="session")
def diarization_pipeline():
    """A loaded pyannote pipeline, shared across the whole test session.

    Loaded **offline** from PulsarTrace's HF cache (see `_configure_offline_hf`)
    so the suite runs sandboxed. Skips cleanly when the token or the prefetched
    model is missing, so a developer who has not run the prefetch step still
    gets a green (skipped) run rather than a failure.
    """
    _load_dotenv()
    if not os.environ.get("HF_TOKEN"):
        pytest.skip("HF_TOKEN not set — pyannote community-1 is gated")
    if not _diarization_model_cached():
        pytest.skip(_PREFETCH_HINT)

    from huggingface_hub.errors import (
        LocalEntryNotFoundError,
        OfflineModeIsEnabled,
    )

    from pulsartrace_ai.diarize import load_pipeline

    try:
        return load_pipeline()
    except (LocalEntryNotFoundError, OfflineModeIsEnabled):
        # A model asset missing from the offline cache (e.g. an interrupted
        # prefetch) → skip, don't error: the developer needs to (re-)run the
        # prefetch step, not debug a test. Any other failure is a real error.
        pytest.skip(_PREFETCH_HINT)
