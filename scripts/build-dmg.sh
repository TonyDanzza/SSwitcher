#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
PACKAGE_DIR="$PWD/build/dmg"
APP_DIR="$PACKAGE_DIR/SSwitcher.app"
DMG="$PWD/build/SSwitcher-$VERSION-universal.dmg"
VENV="$PWD/.build/dmg-tools"
mkdir -p "$PACKAGE_DIR"

# These dependencies are only needed by the packager, never by app users.
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --disable-pip-version-check -r scripts/dmg-requirements.txt
SSWITCHER_UNIVERSAL=1 SSWITCHER_APP_DIR="$APP_DIR" bash scripts/build-app.sh
xcrun swift scripts/dmg-background.swift "$PACKAGE_DIR/background.tiff"

"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D "app=$APP_DIR" -D "background=$PACKAGE_DIR/background.tiff" \
    "SSwitcher $VERSION" "$DMG"
hdiutil verify "$DMG"
"$VENV/bin/python" scripts/verify-dmg.py "$DMG"
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf 'Built %s\n' "$DMG"
printf 'This script does not notarize the app. Public downloads may require Open Anyway in macOS Privacy & Security.\n'
