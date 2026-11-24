# Mugi

Local image upscaler for Apple Silicon. A SwiftUI app (`macOS/`) drives a Python engine (`upscale.py`, `seedvr2.py`) that runs DRCT-L, HAT-L, or SeedVR2 through Metal. See `README.md` for what the app does and how to use it.

## Commands

Run everything from the repository root. The JS tooling is only for formatting and linting; the app itself has no Node code.

| Task                                    | Command                          |
| --------------------------------------- | -------------------------------- |
| Install dev tooling                     | `pnpm install --frozen-lockfile` |
| All fast checks (what CI runs)          | `pnpm run check`                 |
| Format all files                        | `pnpm run fmt`                   |
| Check formatting only                   | `pnpm run fmt:check`             |
| Lint                                    | `pnpm run lint`                  |
| Unit tests                              | `pnpm run test`                  |
| Real upscale smoke test (manual only)   | `pnpm run test:manual`           |
| Build the app                           | `./build-app.sh`                 |
| First-time setup of Python env, weights | `./setup.sh`                     |

Run `pnpm run check` before every commit. It must stay fast: no model loading, no image upscaling, no network.

## Rules

- **Never run the real upscale in CI.** `scripts/smoke-upscale.sh` (`pnpm run test:manual`) loads a real model and is for local use only. Do not add it to `.github/workflows/`.
- **Unit tests stub `torch` and `spandrel`** (see `tests/test_engine.py`) so they need only Pillow. Keep new tests free of model weights and the GPU.
- **Formatting is Oxfmt, linting is Oxlint** (`.oxfmtrc.json`, `.oxlintrc.json`). Oxlint only understands JS and TS, and Oxfmt does not format Python, Swift, or shell. The Swift, Python, and shell sources have no formatter or linter; match the surrounding style.
- **Python dependencies are pinned** in `pyproject.toml` and `uv.lock`. Use `uv run --locked`.
- `models/`, `seedvr2-runtime/`, `.venv/`, `input/`, `output/`, and `build/` are gitignored. Do not commit them.

## Git worktrees

`t3.json` registers `scripts/setup-worktree.mjs`, which T3 Code runs automatically in every new worktree. It links `models/` from the main checkout, runs `pnpm install --frozen-lockfile`, then `./setup.sh`. If a worktree looks unprepared, run `node scripts/setup-worktree.mjs`.

## Releases

Releases are automated. Do not create them by hand with `gh release create`.

1. Merge to `main` and wait for CI to pass.
2. Start the **macOS Release** workflow (`.github/workflows/macos-release.yml`) from `main` with a new `MAJOR.MINOR.PATCH` version.
3. It builds the DMG and publishes a release titled `Mugi <version>` (tag `v<version>`) with `mugi-<version>-arm64.dmg`, its `.sha256`, `packaging/INSTALL.md`, and generated notes.

The workflow fails if `v<version>` already exists. To redo a release, delete both the release and its tag (`gh release delete v<version> --cleanup-tag`) first, because a leftover tag keeps pointing at the old commit. The user-facing name is **Mugi**; the repository is `mugi-upscale`. Do not reintroduce the old placeholder name "4K Upscaler".

## License

The code is under the PolyForm Noncommercial License 1.0.0 (`LICENSE`). It is source-available, not open source: never call it "open source" or "MIT", and never add MIT or other permissive headers or badges. Commercial and internal business use needs a separate commercial license from the owner. Keep third-party licenses and credits intact (models are CC BY 4.0, SeedVR2 is upstream-licensed).
