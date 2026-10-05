#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/build/SSwitcher.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SSwitcher" "$APP_DIR/Contents/MacOS/SSwitcher"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier com.tonydanzza.SSwitcher "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
