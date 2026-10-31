#!/bin/bash
# Install WeatherBar.app to /Applications and launch it.
# Start-at-login is a checkbox inside the app (menu → Settings…), so no LaunchAgent is installed here;
# an older WeatherBar LaunchAgent from v1.0–1.2 is removed to avoid two copies.
# Usage: ./install.sh [path/to/WeatherBar.app]
set -euo pipefail
cd "$(dirname "$0")"
SRC=${1:-build/WeatherBar.app}
[ -d "$SRC" ] || { echo "no app at $SRC — run ./build.sh first"; exit 1; }
PL=~/Library/LaunchAgents/com.mayhoo.weatherbar.plist
if [ -f "$PL" ]; then launchctl bootout "gui/$(id -u)/com.mayhoo.weatherbar" 2>/dev/null || true; rm -f "$PL"; fi
pkill -x WeatherBar 2>/dev/null || true
rm -rf /Applications/WeatherBar.app
cp -R "$SRC" /Applications/WeatherBar.app
xattr -dr com.apple.quarantine /Applications/WeatherBar.app 2>/dev/null || true
open /Applications/WeatherBar.app
echo "WeatherBar installed to /Applications and launched. Turn on 'Start at login' in its Settings."
