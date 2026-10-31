#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The default (swiftbuild) system stamps the binary with SDK 13.0, and AppKit
# then draws every window and menu in the macOS 13 style. Native records the real SDK.
APP_DIR="${SSWITCHER_APP_DIR:-$PWD/build/SSwitcher.app}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
if [[ "${SSWITCHER_UNIVERSAL:-0}" == 1 ]]; then
    BINARIES=()
    for ARCH in arm64 x86_64; do
        BUILD_ARGS=(-c release --build-system native --product SSwitcher
            --triple "$ARCH-apple-macosx13.0" --scratch-path "$PWD/.build/distribution/$ARCH")
        swift build "${BUILD_ARGS[@]}"
        BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
        BINARIES+=("$BIN_DIR/SSwitcher")
    done
    lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/SSwitcher"
else
    swift build -c release --build-system native --product SSwitcher
    BIN_DIR="$(swift build -c release --build-system native --product SSwitcher --show-bin-path)"
    cp "$BIN_DIR/SSwitcher" "$APP_DIR/Contents/MacOS/SSwitcher"
fi
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SSWITCHER_SIGN_IDENTITY:--}" --identifier com.tonydanzza.SSwitcher "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
