"""Upscale photos locally with a Nomos 4× model and save lossless PNGs."""

import argparse
from io import BytesIO
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

from PIL import Image, ImageCms, ImageOps
import spandrel
import torch


MODEL_DIR = Path(__file__).resolve().parent / "models"
MODELS = {
    "drct": MODEL_DIR / "4xNomos2_hq_drct-l.safetensors",
    "hat": MODEL_DIR / "4xNomos8kSCHAT-L.safetensors",
}
EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff"}
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB"))
OVERLAP = 64


def load_image(path):
    with Image.open(path) as source:
        if getattr(source, "n_frames", 1) != 1:
            raise ValueError(f"Expected a single-frame image: {path}")
        source = ImageOps.exif_transpose(source)
        alpha = None
        if "A" in source.getbands() or "transparency" in source.info:
            alpha = source.convert("RGBA").getchannel("A")
        profile = source.info.get("icc_profile")
        if profile:
            if source.mode in {"P", "RGBA"}:
                source = source.convert("RGB")
            elif source.mode == "LA":
                source = source.convert("L")
            source = ImageCms.profileToProfile(
                source, ImageCms.ImageCmsProfile(BytesIO(profile)), SRGB, outputMode="RGB"
            )
        return source.convert("RGB"), alpha


def tile_ranges(length, tile_size):
    start = 0
    while True:
        stop = min(start + tile_size, length)
        yield start, stop
        if stop == length:
            return
        start += tile_size - OVERLAP


def feather(start, stop, length, scale):
    weights = torch.ones((stop - start) * scale)
    # Ignore the least reliable pixels at internal tile borders, then crossfade.
    margin = (OVERLAP // 4) * scale
    ramp = torch.cat((torch.zeros(margin), torch.linspace(0, 1, 2 * margin)))
    if start:
        weights[:len(ramp)] = ramp
    if stop < length:
        weights[-len(ramp):] = ramp.flip(0)
    return weights


@torch.inference_mode()
def upscale_tiled(image, model, tile_size):
    width, height = image.size
    scale = model.scale
    tensor = torch.frombuffer(bytearray(image.tobytes()), dtype=torch.uint8)
    tensor = tensor.reshape(height, width, 3).permute(2, 0, 1).float().div_(255)
    output = torch.zeros((3, height * scale, width * scale))
    weights = torch.zeros((height * scale, width * scale))
    rows = list(tile_ranges(height, tile_size))
    columns = list(tile_ranges(width, tile_size))
    total_tiles = len(rows) * len(columns)
    completed_tiles = 0
    print(f"  Tile 0/{total_tiles}", flush=True)

    for top, bottom in rows:
        wy = feather(top, bottom, height, scale)
        for left, right in columns:
            tile = tensor[:, top:bottom, left:right].unsqueeze(0).contiguous()
            prediction = model(tile.to(model.device))[0].cpu()
            wx = feather(left, right, width, scale)
            mask = wy[:, None] * wx[None, :]
            y = slice(top * scale, bottom * scale)
            x = slice(left * scale, right * scale)
            output[:, y, x].addcmul_(prediction, mask)
            weights[y, x].add_(mask)
            completed_tiles += 1
            print(f"  Tile {completed_tiles}/{total_tiles}", flush=True)

    pixels = output.div_(weights).clamp_(0, 1).mul_(255).round_().to(torch.uint8)
    return Image.frombytes("RGB", (width * scale, height * scale),
                           pixels.permute(1, 2, 0).contiguous().numpy().tobytes())


def save_png(image, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=destination.parent, suffix=".png") as temporary:
        image.save(temporary, format="PNG", icc_profile=SRGB.tobytes())
        temporary.flush()
        os.link(temporary.name, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Image file or folder of images")
    parser.add_argument("-o", "--output", type=Path, help="PNG path for a file, output folder for a batch")
    parser.add_argument("--model", choices=MODELS, default="drct")
    parser.add_argument("--long-edge", type=int, default=3840, help="Target long edge in pixels (default: 3840)")
    parser.add_argument("--tile", type=int, choices=(128, 192, 256, 320, 384), default=256,
                        help="Input tile size (default: 256, use 192 or 128 if memory is tight)")
    parser.add_argument("--device", choices=("mps", "cpu"), default="mps")
    args = parser.parse_args()
    if args.long_edge < 1:
        parser.error("--long-edge must be positive")
    if args.input.is_dir():
        output_dir = args.output or args.input / "upscaled"
        jobs = [(path, output_dir / f"{path.stem}-{path.suffix[1:].lower()}-{args.model}-{args.long_edge}.png")
                for path in sorted(args.input.iterdir())
                if path.is_file() and path.suffix.lower() in EXTENSIONS]
    else:
        destination = args.output or args.input.with_name(
            f"{args.input.stem}-{args.model}-{args.long_edge}.png"
        )
        jobs = [(args.input, destination)]
    if not jobs:
        parser.error(f"No supported images in {args.input}")
    destinations = set()
    for source, destination in jobs:
        if not source.is_file():
            parser.error(f"Input file not found: {source}")
        if destination.suffix.lower() != ".png":
            parser.error(f"Output path must end in .png: {destination}")
        if destination.exists() or destination.resolve() in destinations:
            parser.error(f"Output already exists or collides: {destination}")
        destinations.add(destination.resolve())

    model = None
    try:
        for source, destination in jobs:
            image, alpha = load_image(source)
            longest = max(image.size)
            size = tuple(max(1, round(side * args.long_edge / longest)) for side in image.size)
            print(f"{source.name}: {image.width}×{image.height} to {size[0]}×{size[1]}", flush=True)
            if longest < args.long_edge:
                if model is None:
                    if args.device == "mps" and not torch.backends.mps.is_available():
                        raise ValueError("Metal unavailable. Use --device cpu to run on the CPU.")
                    model = spandrel.ModelLoader().load_from_file(MODELS[args.model])
                    model = model.to(args.device).eval()
                    print(f"  {model.architecture.name} {model.scale}× on {model.device}", flush=True)
                image = upscale_tiled(image, model, args.tile)
                if max(image.size) < args.long_edge:
                    print("  Lanczos enlargement after the model's native 4× pass", flush=True)
            if image.size != size:
                image = image.resize(size, Image.Resampling.LANCZOS)
            if alpha is not None:
                image.putalpha(alpha.resize(size, Image.Resampling.LANCZOS))
            save_png(image, destination)
            print(f"  Saved {destination}", flush=True)
    except (OSError, ValueError, RuntimeError, ImageCms.PyCMSError) as error:
        parser.exit(1, f"Upscaling failed: {error}\n")


if __name__ == "__main__":
    main()
