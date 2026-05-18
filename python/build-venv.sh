#!/usr/bin/env bash
#
# Build the PulsarTrace development Python venv.
#
# Per project-docs/DECISIONS.md D3, the diarization layer runs in a venv created from
# Homebrew's python3.12 (3.12.13), pinned via requirements.lock. The
# python-build-standalone bundling used to ship a self-contained .app is
# deferred to Epic 10.
#
# Usage:
#   python/build-venv.sh           # build .venv in python/pulsartrace-ai/
#
# Idempotent: re-running recreates a clean venv.
set -euo pipefail

PYTHON_BIN="${PULSARTRACE_PYTHON:-/opt/homebrew/bin/python3.12}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="${SCRIPT_DIR}/pulsartrace-ai"
VENV_DIR="${AI_DIR}/.venv"
LOCK_FILE="${AI_DIR}/requirements.lock"

if [ ! -x "${PYTHON_BIN}" ]; then
    echo "error: python interpreter not found at ${PYTHON_BIN}" >&2
    echo "       set PULSARTRACE_PYTHON to override." >&2
    exit 1
fi

echo "[build-venv] interpreter: ${PYTHON_BIN} ($(${PYTHON_BIN} --version 2>&1))"

# Recreate the venv from scratch for a deterministic environment.
rm -rf "${VENV_DIR}"
"${PYTHON_BIN}" -m venv "${VENV_DIR}"

# --quiet only on the pip self-upgrade — its output is noise. The dependency
# and editable installs run without --quiet so a failure's error output (a bad
# pin, an unbuildable wheel) actually reaches the log instead of being swallowed.
# shellcheck disable=SC1091
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip

# Install pinned dependencies. Epic 1's lock contains only the dev tooling
# (pytest); Epic 3 adds the real pyannote/diart/torch pins.
if [ -s "${LOCK_FILE}" ]; then
    echo "[build-venv] installing pinned deps from $(basename "${LOCK_FILE}")"
    "${VENV_DIR}/bin/pip" install -r "${LOCK_FILE}"
fi

# Install the pulsartrace_ai package itself (editable) so `import
# pulsartrace_ai` and the pytest suite resolve.
echo "[build-venv] installing pulsartrace-ai package (editable)"
"${VENV_DIR}/bin/pip" install -e "${AI_DIR}"

# Prefetch the pyannote diarization model into PulsarTrace's HF cache, so the
# pytest diarization suite then runs fully offline — including sandboxed (see
# project-docs/PREWORK.md). Best-effort: a missing HF_TOKEN is a warning, not a
# venv-build failure — the diarization tests just skip until it is prefetched.
echo "[build-venv] prefetching diarization model (offline-test prerequisite)"
if ! "${SCRIPT_DIR}/prefetch-model.sh"; then
    echo "[build-venv] warning: model prefetch did not complete — diarization" >&2
    echo "             tests will skip until python/prefetch-model.sh succeeds" >&2
fi

echo "[build-venv] done — venv at ${VENV_DIR}"
echo "[build-venv] run tests with: ${VENV_DIR}/bin/pytest"
