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
git clone https://github.com/absolutepraya/4k-upscaling.git
cd 4k-upscaling
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

Use **1:1** to inspect the output at one image pixel per display pixel.
Drag either pane to pan both together. The original scales to the same
framing as the output. **Fit** returns to the whole image.

Click **Compare Models** to view DRCT-L and HAT-L side by side. The app
runs any missing model first and keeps both results for the current
photo. Use **Show Original** to switch back, or **Save PNG…** to choose
which model output to export.

Rebuild with `./build-app.sh` after editing the Swift source.

## Install from a DMG

Download the current DMG from [GitHub Releases](https://github.com/absolutepraya/4k-upscaling/releases)
with an account that has access to the repository. Follow the
[installation guide](packaging/INSTALL.md), also included in the disk image.

## Build and release a DMG

On an Apple Silicon Mac with `uv` and the Apple developer tools, run
`./packaging/build-dmg.sh 0.1.0`. The DMG appears under `build/dist/`.
It contains the app, Python, its locked dependencies, and both verified
model files so an installed copy can run offline. The app uses ad-hoc
signing.

The [CI workflow](.github/workflows/ci.yml) checks and builds the app on
pull requests and pushes to `main`. Start the [macOS Release workflow](.github/workflows/macos-release.yml)
from `main` with a new version such as `0.1.0`. It builds the DMG and
publishes it with a SHA-256 checksum and install instructions on GitHub Releases.

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
