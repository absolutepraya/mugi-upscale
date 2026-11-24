#!/bin/sh
# Builds macOS/AppIcon.icns from macOS/icon/mugi-1024.png using system tools.
set -eu
cd "$(dirname "$0")"
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" mugi-1024.png --out "$set_dir/icon_${size}x${size}.png" > /dev/null
    sips -z "$((size * 2))" "$((size * 2))" mugi-1024.png --out "$set_dir/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$set_dir" -o ../AppIcon.icns
rm -rf "$(dirname "$set_dir")"
