#!/bin/bash
# Builds Smart Room and packages it as build/Smart Room.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release "$@"

APP="build/Smart Room.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SmartRoom" "$APP/Contents/MacOS/SmartRoom"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built: $APP"
