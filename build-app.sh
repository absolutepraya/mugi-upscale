#!/bin/sh
set -eu
cd "$(dirname "$0")"
app=${1:-"build/Mugi.app"}
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macOS/Info.plist "$app/Contents/Info.plist"
cp macOS/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -parse-as-library -O \
    macOS/UpscalerApp.swift macOS/ImageViewport.swift -o "$app/Contents/MacOS/Upscaler"
codesign --force --sign - "$app"
printf 'Built %s/%s\n' "$(cd "$(dirname "$app")" && pwd)" "$(basename "$app")"
