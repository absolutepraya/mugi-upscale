"""Crop the padding off Mugi's icons for the README and general assets.

The app icons (mugi-1024.png, mugi-dev-1024.png) keep macOS's transparent margin
so they sit correctly in the Dock. Anywhere else that margin just makes the
icon look small, so this writes copies cropped to the icon's own edge.

Usage (from the repository root):
    uv run --no-project --with pillow==13.0.0 python macOS/icon/make-tight-icons.py
"""

from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parent.parent / "assets"
ICONS = {
    "mugi-1024.png": "mugi-icon.png",
    "mugi-dev-1024.png": "mugi-dev-icon.png",
}


def main():
    ASSETS.mkdir(exist_ok=True)
    for source, name in ICONS.items():
        image = Image.open(HERE / source).convert("RGBA")
        box = image.getchannel("A").getbbox()
        cropped = image.crop(box)
        cropped.save(ASSETS / name)
        print(f"Wrote assets/{name} ({cropped.width}x{cropped.height}, trimmed {box})")


if __name__ == "__main__":
    main()
