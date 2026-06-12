#!/bin/zsh
# Regenerate Resources/AppIcon.icns from Resources/AppIcon.svg.
# Run after editing the SVG; the .icns is committed so make-app.sh
# doesn't depend on this step.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/render-icon.swift Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
