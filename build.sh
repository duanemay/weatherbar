#!/bin/bash
# Build WeatherBar.app with the Swift command-line tools (no Xcode needed).
# Usage: ./build.sh            -> build/WeatherBar.app (ad-hoc signed)
set -euo pipefail
cd "$(dirname "$0")"
APP=build/WeatherBar.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -framework Cocoa -framework CoreLocation -framework ServiceManagement main.swift -o "$APP/Contents/MacOS/WeatherBar"
cp Info.plist "$APP/Contents/Info.plist"
# App icon: icon.png (1024x1024, full-bleed; macOS masks it to the squircle) -> AppIcon.icns
if [ -f icon.png ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  sips -s format png icon.png --out build/icon-src.png >/dev/null   # icon.png may really be a JPEG; iconutil needs true PNGs
  for sz in 16 32 128 256 512; do
    sips -s format png -z $sz $sz build/icon-src.png --out "build/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
    sips -s format png -z $((sz*2)) $((sz*2)) build/icon-src.png --out "build/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi
# Stamp the build date (local time) into the bundle; About shows it.
/usr/libexec/PlistBuddy -c "Add :WBBuildDate string '$(date '+%Y-%m-%d')'" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
