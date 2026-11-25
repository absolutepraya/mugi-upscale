#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-}
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'Usage: %s MAJOR.MINOR.PATCH\n' "$0" >&2
    exit 2
fi
if [[ "$(uname -m)" != arm64 ]]; then
    printf 'Build the DMG on an Apple Silicon Mac.\n' >&2
    exit 2
fi

mkdir -p build/dist
dmg="$PWD/build/dist/mugi-$version-arm64.dmg"
if [[ -e "$dmg" ]]; then
    printf 'The DMG already exists: %s\n' "$dmg" >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/upscaler-dmg.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage="$work/disk"
app="$stage/Mugi.app"
engine="$app/Contents/Resources/engine"
runtime="$engine/python"

./build-app.sh --release "$app"
./setup.sh --models-only
./setup.sh --seedvr2-source
mkdir -p "$engine/models" "$runtime"
cp upscale.py seedvr2.py seedvr2-model.json "$engine/"
cp -R seedvr2-runtime "$engine/"
cp README.md LICENSE packaging/REAL-ESRGAN-LICENSE.txt "$app/Contents/Resources/"
cp models/4xNomos2_hq_drct-l.safetensors models/4xNomos8kSCHAT-L.safetensors \
    models/RealESRGAN_x4plus_anime_6B.pth "$engine/models/"

# uv's managed CPython is relocatable. Install directly into the copy in the bundle.
uv python install 3.12.12 --install-dir "$work/python" --no-bin
ditto "$work/python/cpython-3.12.12-macos-aarch64-none" "$runtime"
python="$runtime/bin/python3.12"
uv export --locked --no-emit-project --no-dev --no-header > "$work/requirements.txt"
uv pip install --no-deps --require-hashes --link-mode copy --python "$python" \
    --target "$runtime/lib/python3.12/site-packages" -r "$work/requirements.txt"
"$python" -I -B "$engine/upscale.py" --help > /dev/null
"$python" -I -B "$engine/seedvr2.py" check > /dev/null

plist="$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "${GITHUB_RUN_NUMBER:-1}" "$plist"

# Ad-hoc sign the embedded arm64 binaries before sealing the app bundle.
while IFS= read -r -d '' file_path; do
    if [[ "$(file -b "$file_path")" == Mach-O* ]]; then
        codesign --force --sign - "$file_path" 2>"$work/codesign.log" || {
            cat "$work/codesign.log" >&2
            exit 1
        }
        codesign --verify --strict "$file_path"
    fi
done < <(find "$runtime" -type f \( -perm -100 -o -name '*.so' -o -name '*.dylib' \) -print0)
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ln -s /Applications "$stage/Applications"
cp packaging/INSTALL.md "$stage/Install Mugi.md"
hdiutil create -volname 'Mugi' -srcfolder "$stage" -fs HFS+ -format UDZO "$work/release.dmg"
hdiutil verify "$work/release.dmg"
mv "$work/release.dmg" "$dmg"
printf 'Built %s\n' "$dmg"
