#!/bin/bash
# Regenerates Resources/AppIcon.icns from make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O make_icon.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/icon_1024.png"

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o ../AppIcon.icns
echo "Done: Resources/AppIcon.icns"
