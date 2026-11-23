# 4K Upscaler

Upscale photos locally on an Apple Silicon Mac. The app uses a native
SwiftUI interface and runs Spandrel and PyTorch on the GPU through Metal.
It accepts PNG, JPEG, WebP, and TIFF and exports lossless 8-bit sRGB PNGs.

## Install from source

You'll need an Apple Silicon Mac with macOS 14 or newer, Swift 6 and a
macOS SDK from Xcode or Apple's Command Line Tools, and
[`uv`](https://docs.astral.sh/uv/getting-started/installation/).
If the Apple tools are missing, run `xcode-select --install`.

```sh
git clone https://github.com/absolutepraya/4K-Upscaling.git
cd 4K-Upscaling
./setup.sh
./build-app.sh
open "build/4K Upscaler.app"
```

Setup creates a local Python environment and downloads and verifies both
model files (about 390 MiB total). Keep the app in the repository's
`build/` directory so it can find the environment and weights. Upscaling
runs offline after setup.

## macOS app

Choose or drop a photo, select a model, and click **Upscale**. When the
second preview appears, click **Save PNG…**. The bar shows completed
tiles. The elapsed timer includes model loading and PNG preparation.

Rebuild with `./build-app.sh` after editing the Swift source.

## Command line

From this directory with `uv` installed:

```sh
uv run --locked upscale.py "/path/to/landscape.png" -o output/landscape-4k.png
```

Batch process a folder:

```sh
uv run --locked upscale.py input -o output
```

Try the second model on the same photo:

```sh
uv run --locked upscale.py "/path/to/landscape.png" --model hat -o output/landscape-hat-4k.png
```

The default is `drct`, trained for clean photographs. `hat` was trained with
JPEG compression and blur. Both models estimate detail. Compare foliage,
fog, fine edges, and repeating textures at 100% zoom to choose the better
fit for a photo.

The default long edge is 3,840 pixels. A 16:9 input becomes 3840 × 2160.
Other ratios keep their framing. Use `--long-edge 4096` for a 4,096-pixel
long edge. Images that already meet the requested size are passed through
or downsampled to fit. Smaller inputs get a native 4× model pass, followed
by a Lanczos resize to the requested dimensions. If the input is under
960 pixels on its long edge, that final resize enlarges beyond the native
4× result.

The model runs in full precision on overlapping tiles. Run one job at a
time. If Metal runs short of memory, retry with `--tile 192` or
`--tile 128`. Use `--device cpu` if Metal is unavailable. The CLI rejects
existing output paths, so use a different filename or directory to rerun.

Use `uv run --locked --offline` to run the CLI without network access
after setup.

## License

The application and CLI source are under the [MIT License](LICENSE).
Setup downloads the following weights from Philip Hofmann's model
repositories under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

- DRCT-L, [4xNomos2_hq_drct-l](https://huggingface.co/Phips/4xNomos2_hq_drct-l)
- HAT-L, [4xNomos8kSCHAT-L](https://huggingface.co/Phips/4xNomos8kSCHAT-L)
