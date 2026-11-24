#!/bin/sh
# Builds an .icns from a 1024 px PNG using system tools.
#   ./make-icns.sh        macOS/AppIcon.icns from mugi-1024.png (Mugi)
#   ./make-icns.sh dev    macOS/AppIcon-dev.icns from mugi-dev-1024.png (Mugi Dev, see make-dev-icon.py)
set -eu
cd "$(dirname "$0")"
case "${1:-}" in
    "") source=mugi-1024.png output=../AppIcon.icns ;;
    dev) source=mugi-dev-1024.png output=../AppIcon-dev.icns ;;
    *) printf 'Usage: %s [dev]\n' "$0" >&2; exit 2 ;;
esac
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source" --out "$set_dir/icon_${size}x${size}.png" > /dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$source" --out "$set_dir/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$set_dir" -o "$output"
rm -rf "$(dirname "$set_dir")"
