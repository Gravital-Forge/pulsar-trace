#!/usr/bin/env bash
#
# Generate the UI-test wrapper project and run the XCUITest suite (PT-R130).
# Extra arguments pass through to xcodebuild, e.g.:
#   scripts/run-ui-tests.sh -only-testing:PulsarTraceUITests/FloorTests
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen not found — install with: brew install xcodegen" >&2
  exit 1
}

# The app under test spawns .build/debug/pulsartrace-engine (and -capture)
# through RecordingViewModel's default binary resolver — build them first.
swift build

xcodegen generate

mkdir -p .build/ui-test-results
# Share one timestamp between the xcresult bundle and the per-run log (PT-R129).
timestamp="$(date +%Y%m%d-%H%M%S)"
log=".build/ui-test-results/$timestamp.log"

# After a screen lock, macOS may re-require the automation-mode password before
# XCUITest can drive the app; an unanswered prompt fails the run in ~60 s. Run
# scripts/start-ui-session.sh after locking to (re)authorize, entering the
# password when the "XCTest is trying to Enable UI Automation" dialog appears.
echo "note: after a screen lock, macOS may require the automation-mode password — unattended runs fail in ~60 s if unanswered; run scripts/start-ui-session.sh after locking to (re)authorize." >&2

# A near-full disk reproducibly stalls the macOS automation session: the
# watchdog kills one random test mid-run — no assertion failure, no crash
# report, just "Restarting after unexpected exit" (observed 2026-07-04 and
# 2026-07-28). The suite's own result bundles are a main consumer; front the
# condition here instead of letting it surface as a mystery kill.
free_gib=$(df -g . | awk 'NR==2 {print $4}')
if [ "$free_gib" -lt 15 ]; then
  echo "warning: only ${free_gib} GiB free on this volume — below ~15 GiB the automation session stalls and random tests die mid-run; prune old runs under .build/ui-test-results/ (keep the latest) before trusting results." >&2
fi

# Hand the real host model cache to the XCUITest runner. The runner process has
# a containerized home, so an in-test `~` derivation resolves to the xctrunner
# container, not the warm cache — xcodebuild surfaces TEST_RUNNER_X as X inside
# the runner, and this script runs unsandboxed in the real user session so its
# $HOME is correct. Respect an already-set override (PT-R134).
#
# Stream xcodebuild while capturing combined output to the log (PT-R129).
# pipefail off so the pipeline's status is tee's (0) and does not trip errexit;
# PIPESTATUS[0] carries xcodebuild's real exit code, which we propagate.
set +o pipefail
TEST_RUNNER_PULSARTRACE_MODELS_DIR="${PULSARTRACE_MODELS_DIR:-$HOME/Library/Caches/PulsarTrace/models}" \
xcodebuild test \
  -project PulsarTraceUIHarness.xcodeproj \
  -scheme UITests \
  -destination 'platform=macOS' \
  -resultBundlePath ".build/ui-test-results/$timestamp.xcresult" \
  "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -o pipefail

if [ "$status" -ne 0 ] && grep -q 'Timed out while enabling automation mode' "$log"; then
  echo "" >&2
  echo "════════════════════════════════════════════════════════════════════════" >&2
  echo " Automation authorization missing — run scripts/start-ui-session.sh," >&2
  echo " enter the password, then retry" >&2
  echo "════════════════════════════════════════════════════════════════════════" >&2
fi

if [ "$status" -ne 0 ] && [ "$free_gib" -lt 15 ] \
  && grep -q 'Restarting after unexpected exit' "$log"; then
  echo "" >&2
  echo "════════════════════════════════════════════════════════════════════════" >&2
  echo " A test died with no assertion failure and this volume has only" >&2
  echo " ${free_gib} GiB free — the known low-disk automation-session stall." >&2
  echo " Free disk space (old .build/ui-test-results/ runs are a main" >&2
  echo " consumer), then retry." >&2
  echo "════════════════════════════════════════════════════════════════════════" >&2
fi

echo "log: $log" >&2
exit "$status"
