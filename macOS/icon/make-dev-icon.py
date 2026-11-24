"""Recolor Mugi's blue background to a soft yellow for the "Mugi Dev" icon.

Usage (from the repository root):
    uv run --no-project --with pillow==13.0.0 --with numpy python macOS/icon/make-dev-icon.py
    ./macOS/icon/make-icns.sh dev

Every pixel is treated as a mix of three source colors (blue background, cream
blob, green leaf). Only the blue share is replaced, so edges stay smooth and the
cream and green stay untouched.
"""

from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "mugi-1024.png"
OUTPUT = HERE / "mugi-dev-1024.png"

BLUE = np.array([122.0, 160.0, 197.0])
CREAM = np.array([253.0, 248.0, 240.0])
GREEN = np.array([80.0, 114.0, 38.0])
YELLOW = np.array([232.0, 198.0, 112.0])


def main():
    image = np.asarray(Image.open(SOURCE).convert("RGBA"), dtype=np.float64)
    rgb, alpha = image[..., :3], image[..., 3:]

    # Solve rgb = a*BLUE + b*CREAM + c*GREEN with a + b + c = 1, per pixel.
    basis = np.stack([BLUE - GREEN, CREAM - GREEN], axis=1)  # 3x2
    weights, *_ = np.linalg.lstsq(basis, (rgb - GREEN).reshape(-1, 3).T, rcond=None)
    blue_share = weights[0].reshape(rgb.shape[:2])
    # Ignore shading noise on the cream and green, and snap flat blue to exactly 1.
    blue_share = np.clip((blue_share - 0.05) / 0.9, 0.0, 1.0)[..., None]
    blue_share = blue_share * (alpha > 0)  # leave fully transparent pixels alone

    shifted = np.clip(rgb + blue_share * (YELLOW - BLUE), 0, 255)
    result = np.concatenate([shifted, alpha], axis=-1).round().astype(np.uint8)
    Image.fromarray(result, "RGBA").save(OUTPUT)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
