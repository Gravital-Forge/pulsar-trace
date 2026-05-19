#!/usr/bin/env bash
#
# Assemble a minimal, UNSIGNED PulsarTrace.app around the `pulsartrace-mac`
# binary so the SwiftUI menubar app can actually be launched during
# development.
#
# This is NOT the Epic 10 distribution bundle: no code signing, no
# notarization, no first-run permissions wizard, no embedded Python runtime.
# It exists only because a SwiftUI `MenuBarExtra` app needs a bundle with an
# `Info.plist` (notably `LSUIElement`) before macOS will give it a menu-bar
# item — a bare `swift run` of the executable launches but shows nothing.
# Epic 10 replaces this with the real signed/notarized bundle.
#
# Usage:  scripts/make-dev-app.sh [debug|release]   (default: debug)
# Then:   open .build/PulsarTrace.app

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"

echo "Building pulsartrace-mac ($CONFIG)…"
swift build --product pulsartrace-mac -c "$CONFIG"

BIN=".build/$CONFIG/pulsartrace-mac"
APP=".build/PulsarTrace.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/pulsartrace-mac"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>pulsartrace-mac</string>
    <key>CFBundleIdentifier</key><string>com.gravitalforge.PulsarTrace</string>
    <key>CFBundleName</key><string>PulsarTrace</string>
    <key>CFBundleDisplayName</key><string>PulsarTrace</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0-dev</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>PulsarTrace records meeting audio for local, on-device transcription.</string>
</dict>
</plist>
PLIST

echo "Assembled $APP"
echo "Launch it with:  open $APP"
echo "(menu-bar-only app — look for the waveform icon, no Dock icon)"
