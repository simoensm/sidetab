#!/bin/bash
# Builds Resources/AppIcon.icns from Tools/icon-1024.png.
# The PNG is rendered from Tools/icon.svg (Liquid Glass style, macOS 26 icon grid).
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Tools/icon-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Tools/icon-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "Made Resources/AppIcon.icns"
