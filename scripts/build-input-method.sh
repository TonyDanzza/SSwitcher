#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product SSwitcherInputMethod
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/build/SSwitcher Input.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SSwitcherInputMethod" "$APP_DIR/Contents/MacOS/SSwitcherInputMethod"
cp Resources/InputMethod/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R Resources/InputMethod/en.lproj Resources/InputMethod/ru.lproj "$APP_DIR/Contents/Resources/"
codesign --force --sign "${SSWITCHER_SIGN_IDENTITY:--}" --identifier com.tonydanzza.inputmethod.SSwitcher "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
