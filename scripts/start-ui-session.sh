#!/usr/bin/env bash
#
# Start a dev UI-automation session (PT-P7-R4): front the macOS Automation-Mode
# authorization prompt at a chosen moment by running the 15-second launch smoke,
# then print one unambiguous verdict about whether automation is now authorized.
#
# macOS gates XCUITest behind "Automation Mode", enabled per session by
# testmanagerd — sometimes via a SecurityAgent password dialog ("XCTest is
# trying to Enable UI Automation"). The grant lasts until the screen locks or
# you log out. Run this once at the start of a dev session and again after every
# screen lock, so later UI suites run unattended instead of failing on a missed
# prompt (~60 s to `Timed out while enabling automation mode`).
set -euo pipefail

# Resolve the script dir before we cd, so the run-ui-tests.sh invocation and the
# log path are stable no matter where the script was called from.
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir/.."

log_dir=".build/ui-test-results"
mkdir -p "$log_dir"
log="$log_dir/session-$(date +%Y%m%d-%H%M%S).log"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
say() { echo "[$(ts)] $*"; }

say "=================================================================="
say "PulsarTrace — start UI-automation session (PT-P7-R4)"
say "=================================================================="
say "About to request macOS Automation-Mode authorization by running the"
say "15-second UI launch smoke (LaunchSmokeTests)."
say ""
say "  >> If a password dialog titled \"XCTest is trying to Enable UI"
say "     Automation\" appears, ENTER YOUR LOGIN PASSWORD. <<"
say ""
say "Once granted, the authorization lasts until the screen locks or you"
say "log out — re-run this script after any screen lock to re-authorize."
say "Session log: $log"
say "------------------------------------------------------------------"

# Run the launch smoke, streaming to the terminal and capturing to the log.
# Disable errexit/pipefail so a nonzero exit does not abort before we classify
# it; PIPESTATUS[0] holds the runner's real exit code (tee's is the pipeline's).
set +e
set +o pipefail
"$script_dir/run-ui-tests.sh" \
  -only-testing:PulsarTraceUITests/LaunchSmokeTests 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
set -o pipefail

say "------------------------------------------------------------------"
say "=================== SESSION VERDICT ==============================="
# Classify from the captured log. Note: LaunchSmokeTests only asserts the status
# item *appears* (waitForExistence) — it never drives the panel, so
# PanelDriver's "status item not placeable on-screen" skip cannot occur here; a
# placement problem therefore falls into the generic-failure branch below.
if grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
  say "✅ Automation session ACTIVE — valid until screen lock/logout. UI suites can now run unattended."
  say "=================================================================="
  exit 0
elif grep -q 'Timed out while enabling automation mode' "$log"; then
  say "❌ Authorization NOT granted — the password prompt was missed or dismissed. Re-run this script and enter the password when the dialog appears."
  say "=================================================================="
  exit 1
else
  say "❌ Session start failed for another reason — see the log:"
  say "   $log"
  say "=================================================================="
  # Propagate the runner's exit code; guarantee nonzero even if it was 0.
  exit "$(( status == 0 ? 1 : status ))"
fi
