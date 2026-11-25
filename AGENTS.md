# Mugi

Local image upscaler for Apple Silicon. A SwiftUI app (`macOS/`) drives a Python engine (`upscale.py`, `seedvr2.py`) that runs DRCT-L, HAT-L, or SeedVR2 through Metal. See `README.md` for what the app does and how to use it.

## Commands

Run everything from the repository root. The JS tooling is only for formatting and linting; the app itself has no Node code.

| Task                                         | Command                          |
| -------------------------------------------- | -------------------------------- |
| Install dev tooling                          | `pnpm install --frozen-lockfile` |
| All fast checks (what CI runs)               | `pnpm run check`                 |
| Format all files                             | `pnpm run fmt`                   |
| Check formatting only                        | `pnpm run fmt:check`             |
| Lint                                         | `pnpm run lint`                  |
| Unit tests                                   | `pnpm run test`                  |
| Script syntax checks                         | `pnpm run check:syntax`          |
| `uv.lock` matches `pyproject.toml`           | `pnpm run check:lock`            |
| Shellcheck (needs `brew install shellcheck`) | `pnpm run lint:shell`            |
| Real upscale smoke test (manual only)        | `pnpm run test:manual`           |
| Build the dev app ("Mugi Dev")               | `./build-app.sh`                 |
| Build the production app ("Mugi")            | `./build-app.sh --release`       |
| First-time setup of Python env, weights      | `./setup.sh`                     |

Run `pnpm run check` before every commit. It must stay fast: no model loading, no image upscaling, no network.

`pnpm run check` covers the format check, lint, `check:syntax`, `check:lock`, and the unit tests. `lint:shell` is separate because it needs `shellcheck` installed; CI runs it.

## CI

- `.github/workflows/ci.yml` runs on pull requests and pushes to `main`. A new push to a PR cancels the run it supersedes.
- **`lint-test`** (Ubuntu): `pnpm run check` and `pnpm run lint:shell`. It gates the next job.
- **`check`** (macOS): `./build-app.sh` and `./build-app.sh --release`, then verifies both signatures.
- Both must pass before merging. Merge PRs with a merge commit, as the history does.
- Dependabot (`.github/dependabot.yml`) opens weekly PRs for GitHub Actions, npm, and uv. Actions are pinned by SHA and tools by exact version, so these PRs are how they stay current.

## Rules

- **Never run the real upscale in CI.** `scripts/smoke-upscale.sh` (`pnpm run test:manual`) loads a real model and is for local use only. Do not add it to `.github/workflows/`.
- **Unit tests stub `torch` and `spandrel`** (see `tests/test_engine.py`) so they need only Pillow. Keep new tests free of model weights and the GPU.
- **Formatting is Oxfmt, linting is Oxlint** (`.oxfmtrc.json`, `.oxlintrc.json`). Oxlint only understands JS and TS, and Oxfmt does not format Python, Swift, or shell. The Swift, Python, and shell sources have no formatter or linter; match the surrounding style.
- **Python dependencies are pinned** in `pyproject.toml` and `uv.lock`. Use `uv run --locked`.
- `models/`, `seedvr2-runtime/`, `.venv/`, `input/`, `output/`, and `build/` are gitignored. Do not commit them.

## Build identities

- **Dev** (`./build-app.sh`, default): `build/Mugi Dev.app`, bundle ID `dev.abhipraya.local-upscaler.dev`, version `dev`, yellow icon. Use it for all local testing. It has its own settings and SeedVR2 cache, and runs next to an installed Mugi.
- **Release** (`./build-app.sh --release`): `Mugi`, bundle ID `dev.abhipraya.local-upscaler`. Only the DMG script and CI use it.
- Never run a dev build as the installed app, and never change the production bundle ID, because that would orphan users' settings.

## Icons

- The app icons in `macOS/icon/` (`mugi-1024.png`, `mugi-dev-1024.png`) keep macOS's transparent margin on purpose, so they sit correctly in the Dock. `macOS/icon/make-icns.sh` builds `macOS/AppIcon.icns`, and `make-icns.sh dev` builds `macOS/AppIcon-dev.icns`.
- The yellow dev icon is generated from the base icon by `macOS/icon/make-dev-icon.py`. If the base icon changes, rerun it, then `make-icns.sh` and `make-icns.sh dev`.
- `assets/` holds padding-free copies of both icons for the README, T3 Code, and other uses. Regenerate them with `macOS/icon/make-tight-icons.py`. Do not use the padded app icons where an icon would look small.

## Git worktrees

`t3.json` registers `scripts/setup-worktree.mjs`, which T3 Code runs automatically in every new worktree (and adds Check and Format buttons to its scripts menu). It links `models/` from the main checkout, runs `pnpm install --frozen-lockfile`, then `./setup.sh`. If a worktree looks unprepared, run `node scripts/setup-worktree.mjs`.

## Pull requests

- **Include at least one screenshot of what changed** in the PR description whenever the PR changes the app (its UI or behavior you can see). Show the changed window, state, or setting so a reviewer sees the change without building it. Capture just that window rather than the whole screen, so nothing unrelated is shown.
- **Skip the screenshot** for PRs that do not change the app, such as the README, license, `AGENTS.md`, CI, or other config and tooling. Say in the PR that the change has nothing to show.

## Releases

Releases are automated. Do not create them by hand with `gh release create`.

1. Merge to `main` and wait for CI to pass.
2. Start the **macOS Release** workflow (`.github/workflows/macos-release.yml`) from `main` with a new `MAJOR.MINOR.PATCH` version.
3. It builds the DMG and publishes a release titled `Mugi <version>` (tag `v<version>`) with `mugi-<version>-arm64.dmg`, its `.sha256`, `packaging/INSTALL.md`, and generated notes.

The app updates itself from these releases (`macOS/Updater.swift`). It reads the latest release from the GitHub API without a token, so the repository must stay public, and it expects the assets `mugi-<version>-arm64.dmg` and `mugi-<version>-arm64.dmg.sha256` and a DMG whose app has the production bundle ID and the release version. Keep the asset names and that packaging if you change the release workflow or `packaging/build-dmg.sh`. To test an update end to end, build a copy with a lower `CFBundleShortVersionString` and a different bundle ID outside `/Applications`.

The workflow fails if `v<version>` already exists. To redo a release, delete both the release and its tag (`gh release delete v<version> --cleanup-tag`) first, because a leftover tag keeps pointing at the old commit. The user-facing name is **Mugi**; the repository is `mugi-upscale`. Do not reintroduce the old placeholder name "4K Upscaler".

## License

The code is under the PolyForm Noncommercial License 1.0.0 (`LICENSE`). It is source-available, not open source: never call it "open source" or "MIT", and never add MIT or other permissive headers or badges. Commercial and internal business use needs a separate commercial license from the owner. Keep third-party licenses and credits intact (models are CC BY 4.0, SeedVR2 is upstream-licensed).

## Docs

Keep the docs in step with the code in the same PR. When the app's UI or the CLI options change, update `README.md` (the "Use the app" steps, the Settings list, and the CLI table). When a command, CI job, build identity, or release step changes, update this file. `CLAUDE.md` is a symlink to `AGENTS.md`; edit `AGENTS.md`.
