#!/usr/bin/env bash
#
# Generate the UI-test wrapper project and run the XCUITest suite (PT-P7-R5).
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
exec xcodebuild test \
  -project PulsarTraceUIHarness.xcodeproj \
  -scheme UITests \
  -destination 'platform=macOS' \
  -resultBundlePath ".build/ui-test-results/$(date +%Y%m%d-%H%M%S).xcresult" \
  "$@"
