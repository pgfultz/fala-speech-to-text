#!/bin/zsh
# Builds Fala.app (release) into ./build. Pass --install to copy it to /Applications and launch it.
# Set FALA_SIGN_IDENTITY to a codesigning identity to keep macOS permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Fala.app
swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Fala "$APP/Contents/MacOS/Fala"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
  rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "${FALA_SIGN_IDENTITY:--}" --identifier dev.fala.app "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Fala 2>/dev/null || true
  rm -rf /Applications/Fala.app
  cp -R "$APP" /Applications/Fala.app
  open /Applications/Fala.app
  echo "Installed to /Applications/Fala.app"
fi
