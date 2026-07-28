#!/usr/bin/env bash
#
# App-level real-audio smoke (PT-P7-R7): play a committed voice sample through
# BlackHole into the shipped record path (capture daemon → engine live pass →
# refinement) and check the refined transcript against the sample's reference.
#
# Prereqs (docs/development.md): BlackHole 2ch, `brew install switchaudio-osx`,
# and Microphone TCC granted to this terminal. Not a CI gate (PT-P7-D4/D5).
#
# Usage: scripts/e2e-audio-smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in SwitchAudioSource afplay; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing: $tool (brew install switchaudio-osx)" >&2; exit 1; }
done

echo "Building…"
swift build
CLI=.build/debug/pulsartrace

# --- BlackHole as the mic -----------------------------------------------
MIC_LINE=$("$CLI" record --list-mics | grep -i blackhole | head -1 || true)
[ -n "$MIC_LINE" ] || {
  echo "BlackHole 2ch not visible as an input device — install it:" >&2
  echo "  brew install --cask blackhole-2ch   (then retry)" >&2; exit 1; }
MIC_INDEX=$(printf '%s\n' "$MIC_LINE" | sed 's/[^0-9]*\([0-9][0-9]*\).*/\1/')
echo "Using mic [$MIC_INDEX]: $MIC_LINE"

# --- isolated state (PT-P7-R9) ------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
export PULSARTRACE_HOME="${TMPDIR:-/tmp}/pt-audio-smoke-home-$STAMP"
OUT="${TMPDIR:-/tmp}/pt-audio-smoke-out-$STAMP"
mkdir -p "$PULSARTRACE_HOME" "$OUT"

# --- route default output to BlackHole, restore on ANY exit --------------
PREV_OUTPUT=$(SwitchAudioSource -c -t output)
restore() { SwitchAudioSource -t output -s "$PREV_OUTPUT" >/dev/null || true; }
trap restore EXIT
SwitchAudioSource -t output -s "BlackHole 2ch" >/dev/null
# Output volume scales the signal into BlackHole (it is per-device — the real
# speakers' volume is untouched); same idiom as audio-loopback-check.sh.
osascript -e 'set volume output volume 90' >/dev/null 2>&1 || true

# --- record mic-only while the sample plays ------------------------------
# Capture first, then play — the loopback check's sequence: the daemon needs
# a moment to open the device, and the sample's opening sentences carry
# reference keywords that would otherwise be clipped.
SAMPLE=audio-samples/sample-1-roger.mp3
REFERENCE=audio-samples/sample-1-roger.md
"$CLI" record --duration 1 --mic "$MIC_INDEX" --no-system-audio --output "$OUT" &
RECORD_PID=$!
sleep 3
afplay "$SAMPLE"
wait "$RECORD_PID"
restore; trap - EXIT

# --- assert the refined transcript ---------------------------------------
FINAL=$(find "$OUT" -name final.md | head -1)
[ -n "$FINAL" ] || { echo "no final.md produced under $OUT" >&2; exit 1; }

# Five distinctive words from the committed reference; ASR variance means we
# require 3 of 5, mirroring the loopback check's tolerance.
KEYWORDS=$(tr -c '[:alnum:]' ' ' < "$REFERENCE" | tr '[:upper:]' '[:lower:]' \
  | tr ' ' '\n' | awk 'length($0) >= 7' | sort | uniq | head -5)
[ -n "$KEYWORDS" ] || { echo "no usable keywords in $REFERENCE" >&2; exit 1; }
HITS=0
for word in $KEYWORDS; do
  if grep -qi "$word" "$FINAL"; then
    HITS=$((HITS + 1)); echo "  ✓ $word"
  else
    echo "  ✗ $word"
  fi
done
echo "Matched $HITS/5 reference keywords in $FINAL"
echo "Isolated home: $PULSARTRACE_HOME"
if [ "$HITS" -lt 3 ]; then
  echo "FAIL: transcript does not match the reference" >&2
  echo "  (an empty or near-empty transcript usually means this terminal has" >&2
  echo "   no Microphone permission — System Settings → Privacy & Security)" >&2
  exit 1
fi
echo "PASS"
