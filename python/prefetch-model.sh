#!/usr/bin/env bash
#
# Prefetch the pyannote diarization model into PulsarTrace's Hugging Face
# cache (DECISIONS.md D10).
#
# Run this ONCE after cloning, **online** — it is the only network step the
# diarization test suite needs. Afterwards `pytest` loads the model offline
# from the cache, so the suite runs anywhere, including inside the Claude Code
# Bash sandbox (whose network egress cannot carry huggingface_hub's Hub call).
#
# build-venv.sh runs this as its final step, so a plain `python/build-venv.sh`
# is the whole post-clone init. Re-run standalone any time; idempotent — a
# fully cached model is a fast no-op.
#
# HF_TOKEN is read from the environment, else from the repo `.env` (dev-only
# fallback, DECISIONS.md D9/D10). pyannote community-1 is a gated model.
#
# Usage:
#   python/prefetch-model.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_PY="${SCRIPT_DIR}/pulsartrace-ai/.venv/bin/python"

if [ ! -x "${VENV_PY}" ]; then
    echo "error: venv python not found at ${VENV_PY}" >&2
    echo "       run python/build-venv.sh first." >&2
    exit 1
fi

REPO_ROOT="${REPO_ROOT}" "${VENV_PY}" - <<'PY'
import os
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])

# HF_TOKEN from the environment, else the repo .env (dev fallback, D9/D10).
if not os.environ.get("HF_TOKEN"):
    env_file = repo_root / ".env"
    if env_file.is_file():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                os.environ.setdefault(
                    key.strip(), value.strip().strip('"').strip("'")
                )

if not os.environ.get("HF_TOKEN"):
    sys.exit(
        "error: HF_TOKEN not set (environment or .env) — "
        "pyannote community-1 is a gated model"
    )

# Online download into PulsarTrace's cache. load_pipeline() points HF_HOME at
# that cache and pulls the model on first call; a second run is a no-op.
from pulsartrace_ai.diarize import load_pipeline

print("[prefetch-model] fetching pyannote community-1 (first run downloads)...")
load_pipeline()
print("[prefetch-model] done — model cached; the pytest suite now runs offline")
PY
