#!/usr/bin/env bash
#
# build-whisper.sh — vendor + build whisper.cpp for PulsarTrace (Epic 2).
#
# Clones whisper.cpp pinned to a specific commit (if absent) and builds it with
# cmake + Metal acceleration, with the Metal shader library embedded into the
# binary (-DGGML_METAL_EMBED_LIBRARY=ON) so no separate .metallib file ships.
#
# Output layout (consumed by Package.swift via the `CWhisper` system library
# target — see project-docs/DECISIONS.md D7):
#
#   vendor/whisper.cpp/            checkout (gitignored)
#   vendor/whisper-install/lib     libwhisper.dylib, libggml*.dylib
#   vendor/whisper-install/include whisper.h, ggml*.h
#
# Re-running is cheap: an existing checkout at the pinned commit is reused.
#
# Reproducibility: the pinned commit below is the single source of truth and is
# also recorded in project-docs/DECISIONS.md (D7).

set -euo pipefail

# --- Configuration ----------------------------------------------------------

# whisper.cpp v1.8.4 — pinned. See project-docs/DECISIONS.md D7.
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"
WHISPER_COMMIT="9386f239401074690479731c1e41683fbbeac557"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
SRC_DIR="${VENDOR_DIR}/whisper.cpp"
BUILD_DIR="${SRC_DIR}/build"
INSTALL_DIR="${VENDOR_DIR}/whisper-install"

# --- Preconditions ----------------------------------------------------------

command -v git   >/dev/null || { echo "error: git not found"   >&2; exit 1; }
command -v cmake >/dev/null || { echo "error: cmake not found (brew install cmake)" >&2; exit 1; }

# --- Clone (if absent) and pin ----------------------------------------------

mkdir -p "${VENDOR_DIR}"

if [ ! -d "${SRC_DIR}/.git" ]; then
    echo "==> Cloning whisper.cpp into ${SRC_DIR}"
    git clone "${WHISPER_REPO}" "${SRC_DIR}"
fi

echo "==> Pinning whisper.cpp to ${WHISPER_COMMIT}"
git -C "${SRC_DIR}" fetch --depth 1 origin "${WHISPER_COMMIT}" 2>/dev/null \
    || git -C "${SRC_DIR}" fetch origin
git -C "${SRC_DIR}" checkout --quiet --detach "${WHISPER_COMMIT}"

ACTUAL_COMMIT="$(git -C "${SRC_DIR}" rev-parse HEAD)"
if [ "${ACTUAL_COMMIT}" != "${WHISPER_COMMIT}" ]; then
    echo "error: checkout mismatch: got ${ACTUAL_COMMIT}, want ${WHISPER_COMMIT}" >&2
    exit 1
fi

# --- Build with cmake + Metal (embedded shaders) ----------------------------

echo "==> Configuring (Metal, embedded shader library)"
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF

echo "==> Building"
cmake --build "${BUILD_DIR}" --config Release -j"$(sysctl -n hw.ncpu)"

echo "==> Installing into ${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}"
cmake --install "${BUILD_DIR}" --config Release

# --- Verify expected artifacts ----------------------------------------------

HEADER="${INSTALL_DIR}/include/whisper.h"
[ -f "${HEADER}" ] || { echo "error: ${HEADER} missing after install" >&2; exit 1; }

DYLIB="$(ls "${INSTALL_DIR}"/lib/libwhisper*.dylib 2>/dev/null | head -1 || true)"
[ -n "${DYLIB}" ] || { echo "error: libwhisper dylib missing after install" >&2; exit 1; }

echo "==> whisper.cpp ${WHISPER_COMMIT} built OK"
echo "    header : ${HEADER}"
echo "    libdir : ${INSTALL_DIR}/lib"
ls -1 "${INSTALL_DIR}/lib"
