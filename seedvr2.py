"""Run the pinned SeedVR2 image pipeline inside Mugi's local engine process."""

from contextlib import contextmanager
from fcntl import LOCK_EX, LOCK_SH, flock
from hashlib import file_digest
from http.client import HTTPException
from importlib import import_module
import json
from math import ceil, isqrt
import os
from pathlib import Path
import sys
from time import monotonic
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from PIL import Image


REVISION = "4490bd1f482e026674543386bb2a4d176da245b9"
ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "seedvr2-runtime" / REVISION
DEFAULT_CACHE = Path.home() / "Library" / "Caches" / "dev.abhipraya.local-upscaler" / "SeedVR2"
CACHE = Path(os.environ.get("MUGI_SEEDVR2_CACHE", DEFAULT_CACHE))
WEIGHTS = json.loads((ROOT / "seedvr2-model.json").read_text(encoding="utf-8"))
DIT_MODEL = "seedvr2_ema_3b-Q8_0.gguf"


def check_runtime_source():
    if not (SOURCE / "inference_cli.py").is_file():
        raise RuntimeError("SeedVR2's local engine is missing. Run ./setup.sh again or reinstall Mugi.")


def load_runtime():
    check_runtime_source()
    # Keep PyTorch's allocator limits on Metal. The standalone upstream CLI disables them.
    os.environ.setdefault("PYTORCH_MPS_HIGH_WATERMARK_RATIO", "1.7")
    os.environ.setdefault("PYTORCH_MPS_LOW_WATERMARK_RATIO", "1.4")
    sys.path.insert(0, str(SOURCE))
    try:
        return import_module("inference_cli")
    except ImportError as error:
        raise RuntimeError(f"SeedVR2 could not load. Run ./setup.sh again or reinstall Mugi. ({error})") from error


def matches_digest(path, expected):
    if not path.is_file():
        return False
    with path.open("rb") as stream:
        return file_digest(stream, "sha256").hexdigest() == expected


def report_transfer(received, total, speed):
    if os.environ.get("MUGI_ENGINE_EVENTS") == "1":
        print(f"Download {received} {total} {speed}", flush=True)
    else:
        percent = min(100, received * 100 // total)
        print(f"  SeedVR2 download: {percent}% ({speed / 1_000_000:.1f} MB/s)", flush=True)


def download_weights(url, partial, label, completed, total_model_bytes):
    offset = partial.stat().st_size if partial.exists() else 0
    request = Request(url, headers={"Range": f"bytes={offset}-"} if offset else {})
    try:
        response = urlopen(request, timeout=30)
    except HTTPError as error:
        if error.code != 416 or not offset:
            raise
        # The partial download is no longer a valid range for this file.
        error.close()
        partial.unlink()
        offset = 0
        response = urlopen(url, timeout=30)
    with response:
        if response.status == 206:
            content_range = response.headers.get("Content-Range", "")
            if not content_range.startswith(f"bytes {offset}-"):
                raise ValueError("SeedVR2 download returned an unexpected byte range. Try again.")
        else:
            offset = 0
        length = response.headers.get("Content-Length")
        total = offset + int(length) if length else None
        received = offset
        last_sample = monotonic()
        last_received = received
        report_transfer(completed + received, total_model_bytes, 0)
        with partial.open("ab" if offset else "wb") as stream:
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
                received += len(chunk)
                now = monotonic()
                interval = now - last_sample
                if interval >= 0.3:
                    speed = int((received - last_received) / interval)
                    report_transfer(completed + received, total_model_bytes, speed)
                    last_sample, last_received = now, received
        if total is not None and total != received:
            raise RuntimeError(f"The SeedVR2 {label} download was interrupted. Try again to resume.")
        report_transfer(completed + received, total_model_bytes, 0)


@contextmanager
def model_lock(mode):
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / ".download.lock").open("a") as lock:
        flock(lock, mode)
        yield


def prepare_weights(allow_download):
    print("Status Checking SeedVR2 model files…", flush=True)
    completed = 0
    total = sum(weight["bytes"] for weight in WEIGHTS)
    for weight in WEIGHTS:
        name = weight["name"]
        digest = weight["sha256"]
        target = CACHE / name
        partial = CACHE / (name + ".download")
        if matches_digest(target, digest):
            completed += weight["bytes"]
            continue
        if not allow_download:
            raise ValueError("SeedVR2 model files are missing or damaged. Download the model in Mugi or remove damaged files in Settings first.")
        label = "model" if name == DIT_MODEL else "decoder"
        print(f"Status Downloading SeedVR2 {label}…", flush=True)
        url = f'https://huggingface.co/{weight["repo"]}/resolve/main/{name}'
        try:
            if not matches_digest(partial, digest):
                download_weights(url, partial, label, completed, total)
            print(f"Status Verifying SeedVR2 {label}…", flush=True)
            if not matches_digest(partial, digest):
                partial.unlink()
                raise ValueError(f"SeedVR2 {label} download failed verification. Try again.")
            partial.replace(target)
        except (URLError, HTTPException, TimeoutError) as error:
            raise RuntimeError(f"Could not download the SeedVR2 {label}. Check your connection and try again.") from error
        completed += weight["bytes"]


def remove_weights():
    for weight in WEIGHTS:
        name = weight["name"]
        (CACHE / name).unlink(missing_ok=True)
        (CACHE / (name + ".download")).unlink(missing_ok=True)


def inference_edge(image, output_edge, memory_bytes):
    # Keep the diffusion pass within a 4K frame's pixel budget, with a smaller
    # budget on Macs with less unified memory. The caller resizes to the output size.
    memory_gib = memory_bytes / (1024 ** 3)
    budget = 3840 * 2160 if memory_gib >= 24 else 2560 * 1440 if memory_gib >= 16 else 1920 * 1080
    long_edge, short_edge = max(image.size), min(image.size)
    return min(output_edge, 4096, isqrt(budget * long_edge // short_edge))


class SeedVR2:
    def __init__(self, allow_download=True):
        self.runtime = None
        self.allow_download = allow_download

    def upscale(self, image, output_edge):
        import psutil
        import torch

        edge = inference_edge(image, output_edge, psutil.virtual_memory().total)
        scaled_short_edge = edge * min(image.size) / max(image.size)
        if edge <= max(image.size) or scaled_short_edge < 2:
            print("  Resizing directly to fit SeedVR2's working size.", flush=True)
            return image
        mode = LOCK_EX if self.allow_download and self.runtime is None else LOCK_SH
        with model_lock(mode):
            prepare_weights(allow_download=mode == LOCK_EX)
            return self.generate(image, edge, ceil(scaled_short_edge), torch)

    def generate(self, image, edge, short_edge, torch):
        if self.runtime is None:
            self.runtime = load_runtime()

        runtime = self.runtime
        invocation = sys.argv
        try:
            sys.argv = [
                str(SOURCE / "inference_cli.py"), "image.png",
                "--model_dir", str(CACHE), "--dit_model", DIT_MODEL,
                "--resolution", str(short_edge), "--max_resolution", str(edge),
                "--batch_size", "1", "--color_correction", "wavelet",
                "--vae_encode_tiled", "--vae_decode_tiled",
                "--vae_encode_tile_size", "512", "--vae_decode_tile_size", "512",
            ]
            args = runtime.parse_arguments()
        finally:
            sys.argv = invocation

        print("Status Upscaling with SeedVR2 on Metal…", flush=True)
        frame = torch.frombuffer(bytearray(image.tobytes()), dtype=torch.uint8)
        frame = frame.reshape(1, image.height, image.width, 3).float().div_(255).half()
        with torch.inference_mode():
            result = runtime._process_frames_core(frame, args, "0", runtime.debug)[0]
            pixels = result.float().clamp_(0, 1).mul_(255).round_().to(torch.uint8).contiguous()
        print("Status Finishing image…", flush=True)
        return Image.frombytes("RGB", (pixels.shape[1], pixels.shape[0]), pixels.cpu().numpy().tobytes())


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "download", "delete"))
    args = parser.parse_args()
    try:
        if args.action == "check":
            load_runtime()
        else:
            with model_lock(LOCK_EX):
                if args.action == "download":
                    check_runtime_source()
                    prepare_weights(allow_download=True)
                else:
                    remove_weights()
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"{error}\n")
