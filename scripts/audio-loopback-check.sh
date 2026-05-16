#!/usr/bin/env bash
#
# audio-loopback-check.sh — preflight audio sanity check for PulsarTrace dev.
#
# Verifies this Mac has working capture devices and that the BlackHole virtual
# device round-trips audio. BlackHole is the Layer-3 / Capture test fixture
# (R66) — the shipping app captures system audio via ScreenCaptureKit (R2),
# never BlackHole. This script is a developer diagnostic, not product code.
#
# It:
#   1. enumerates AVFoundation audio input devices,
#   2. plays a known sample into "BlackHole 2ch" and captures it back,
#   3. runs `pulsartrace refine` on the captured WAV.
#
# Playback uses `afplay`, not ffmpeg: macOS has no reliable ffmpeg muxer that
# targets a named CoreAudio *output* device, so we temporarily route the system
# default output to BlackHole and restore it on exit. Capture is a second
# process — ffmpeg reading the BlackHole *input* endpoint.
#
# Usage: scripts/audio-loopback-check.sh [sample.mp3|sample.wav]

set -euo pipefail

BLACKHOLE="BlackHole 2ch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SAMPLE="${1:-${REPO_ROOT}/audio-samples/sample-1-roger.mp3}"
OUTDIR="${REPO_ROOT}/.preflight"

# --- preconditions ----------------------------------------------------------

for t in ffmpeg ffprobe afplay SwitchAudioSource; do
    command -v "$t" >/dev/null || { echo "error: '$t' not found in PATH" >&2; exit 1; }
done
[ -f "$SAMPLE" ] || { echo "error: sample not found: $SAMPLE" >&2; exit 1; }

# Locate the built pulsartrace CLI (release preferred); empty if not built.
PULSARTRACE=""
for c in "${REPO_ROOT}/.build/release/pulsartrace" "${REPO_ROOT}/.build/debug/pulsartrace"; do
    [ -x "$c" ] && { PULSARTRACE="$c"; break; }
done

mkdir -p "$OUTDIR"

# --- 1. enumerate input devices ---------------------------------------------

# The AVFoundation audio-device list, one device per line: "[1] BlackHole 2ch".
# `ffmpeg -list_devices` prints the list to stderr then exits non-zero (the
# empty `-i ""` input is unopenable by design) — hence the `|| true`.
audio_devices() {
    { ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true; } \
        | sed 's/^\[AVFoundation[^]]*\] //' \
        | awk '/audio devices:/{p=1;next} /video devices:/{p=0} p' \
        | grep -E '^\[[0-9]+\]' || true
}

echo "== AVFoundation audio input devices =="
audio_devices
echo

BH_IDX="$(audio_devices | sed -nE "s/^\[([0-9]+)\] ${BLACKHOLE}\$/\1/p")"
[ -n "$BH_IDX" ] || {
    echo "error: '$BLACKHOLE' is not an AVFoundation audio device — is BlackHole installed?" >&2
    exit 1
}
echo "Loopback device: '$BLACKHOLE' at AVFoundation index [$BH_IDX]."

# --- 2. loopback: play sample into BlackHole, capture it back ---------------

DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SAMPLE")"
CAP_SECS=$(( $(printf '%.0f' "$DUR") + 3 ))
CAPTURED="${OUTDIR}/captured.wav"

ORIG_OUT="$(SwitchAudioSource -c -t output)"
restore_output() { SwitchAudioSource -s "$ORIG_OUT" -t output >/dev/null 2>&1 || true; }
trap restore_output EXIT

echo "Routing system output -> '$BLACKHOLE' (restores '$ORIG_OUT' on exit)."
SwitchAudioSource -s "$BLACKHOLE" -t output >/dev/null
osascript -e 'set volume output volume 90' >/dev/null 2>&1 || true

echo "Recording ${CAP_SECS}s from BlackHole while playing $(basename "$SAMPLE") (${DUR}s)..."
# Capture is written straight to the canonical storage format (R54e):
# 16 kHz mono Int16 PCM WAV — what the refinement pipeline expects.
ffmpeg -hide_banner -loglevel error -y \
    -f avfoundation -i ":${BH_IDX}" -t "${CAP_SECS}" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$CAPTURED" &
REC_PID=$!

sleep 1                       # let ffmpeg open the capture device
afplay "$SAMPLE"              # plays into BlackHole (now the default output)
wait "$REC_PID"
restore_output
trap - EXIT

echo "Captured: $CAPTURED"
echo "Level check (silence => loopback failed):"
ffmpeg -hide_banner -nostats -i "$CAPTURED" -af volumedetect -f null - 2>&1 \
    | grep -E 'mean_volume|max_volume' | sed 's/^/  /' || true

# --- 3. transcribe with pulsartrace -----------------------------------------

echo
if [ -z "$PULSARTRACE" ]; then
    echo "warning: pulsartrace CLI not built — skipping transcription."
    echo "         build it: swift build --product pulsartrace"
    exit 0
fi

echo "== pulsartrace refine =="
"$PULSARTRACE" refine "$CAPTURED"

FINAL="$(find "$OUTDIR" -name final.md -print -quit 2>/dev/null || true)"
if [ -n "$FINAL" ]; then
    echo
    echo "== $FINAL =="
    cat "$FINAL"
fi
