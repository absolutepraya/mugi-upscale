#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/4K Upscaler.app"
mkdir -p "$app/Contents/MacOS"
cp macOS/Info.plist "$app/Contents/Info.plist"
xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -parse-as-library -O \
    macOS/UpscalerApp.swift -o "$app/Contents/MacOS/Upscaler"
codesign --force --sign - "$app"
printf 'Built %s\n' "$PWD/$app"
