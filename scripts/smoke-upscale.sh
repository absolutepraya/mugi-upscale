#!/bin/sh
# Manual end-to-end check: really upscales a tiny generated image with a real model.
# Needs the Python environment and model weights from ./setup.sh. Never run in CI.
#
#   pnpm run test:manual                    # DRCT-L, the fastest
#   MODEL=hat pnpm run test:manual
#   MODEL=seedvr2 pnpm run test:manual      # needs the SeedVR2 download, slow
set -eu
cd "$(dirname "$0")/.."

model=${MODEL:-drct}
long_edge=${LONG_EDGE:-1024}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

uv run --locked python - "$work/source.png" <<'PY'
import sys
from PIL import Image

width, height = 192, 108
image = Image.new("RGB", (width, height))
image.putdata([(x * 255 // width, y * 255 // height, 128) for y in range(height) for x in range(width)])
image.save(sys.argv[1])
PY

uv run --locked upscale.py "$work/source.png" --model "$model" --long-edge "$long_edge" -o "$work/result.png"

uv run --locked python - "$work/result.png" "$long_edge" <<'PY'
import sys
from PIL import Image

expected = (int(sys.argv[2]), round(108 * int(sys.argv[2]) / 192))
with Image.open(sys.argv[1]) as result:
    if result.size != expected:
        sys.exit(f"Expected {expected[0]}x{expected[1]}, got {result.width}x{result.height}")
print(f"OK: {result.width}x{result.height} PNG produced")
PY
