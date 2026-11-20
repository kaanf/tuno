#!/bin/bash
# Renders Resources/Icon/AppIcon.svg into Resources/AppIcon.icns.
#
# Run it after changing the SVG; the .icns is committed, so building Tuno
# doesn't depend on this.
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/Icon/AppIcon.svg"
OUT="Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/render-icon" scripts/render-icon.swift
"$WORK/render-icon" "$SVG" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
echo "Wrote $OUT"
