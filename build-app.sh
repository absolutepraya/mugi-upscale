#!/bin/sh
# Build the app bundle.
#   ./build-app.sh                       "Mugi Dev" in build/, its own bundle ID, for local work
#   ./build-app.sh --release [app-path]  "Mugi", the production identity (used by the DMG and CI)
# A dev build has a yellow icon and keeps its own settings and caches, so it never touches an installed Mugi.
set -eu
cd "$(dirname "$0")"
channel=dev
case "${1:-}" in
    --release) channel=release; shift ;;
    -*) printf 'Usage: %s [--release] [app-path]\n' "$0" >&2; exit 2 ;;
esac
if [ "$channel" = release ]; then default="build/Mugi.app"; else default="build/Mugi Dev.app"; fi
app=${1:-$default}
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macOS/Info.plist "$app/Contents/Info.plist"
if [ "$channel" = dev ]; then icon=macOS/AppIcon-dev.icns; else icon=macOS/AppIcon.icns; fi
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
if [ "$channel" = dev ]; then
    plist="$app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string dev.abhipraya.local-upscaler.dev "$plist"
    plutil -replace CFBundleName -string "Mugi Dev" "$plist"
    plutil -replace CFBundleDisplayName -string "Mugi Dev" "$plist"
    plutil -replace CFBundleShortVersionString -string dev "$plist"
fi
xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0 -parse-as-library -O \
    macOS/UpscalerApp.swift macOS/ImageViewport.swift macOS/ModelDownloads.swift macOS/SystemStats.swift -o "$app/Contents/MacOS/Upscaler"
codesign --force --sign - "$app"
printf 'Built %s/%s\n' "$(cd "$(dirname "$app")" && pwd)" "$(basename "$app")"
