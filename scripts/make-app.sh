#!/bin/zsh
# Build MeetNote.app (menu bar app) and install it into /Applications.
# NOTE: the bundle is ad-hoc signed, so every rebuild changes its code
# signature — macOS will drop the System Audio Recording grant. After
# reinstalling, re-toggle MeetNote in System Settings → Privacy & Security
# → Screen & System Audio Recording → System Audio Recording Only.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="/Applications/MeetNote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetnoteBar "$APP/Contents/MacOS/MeetNote"
cp Resources/MeetNote-Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Installed $APP"
