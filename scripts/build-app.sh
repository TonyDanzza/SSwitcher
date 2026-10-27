#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The default (swiftbuild) system stamps the binary with SDK 13.0, and AppKit
# then draws every window and menu in the macOS 13 style. Native records the real SDK.
swift build -c release --build-system native --product SSwitcher
BIN_DIR="$(swift build -c release --build-system native --product SSwitcher --show-bin-path)"
APP_DIR="$PWD/build/SSwitcher.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SSwitcher" "$APP_DIR/Contents/MacOS/SSwitcher"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SSWITCHER_SIGN_IDENTITY:--}" --identifier com.tonydanzza.SSwitcher "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
