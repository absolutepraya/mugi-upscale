#!/bin/sh
set -eu
cd "$(dirname "$0")"

case "${1:-}" in
    "") uv sync --locked --python 3.12
        mkdir -p input output
        ./setup.sh --seedvr2-source ;;
    --models-only) ;;
    --seedvr2-source)
        revision=4490bd1f482e026674543386bb2a4d176da245b9
        checksum=73ebee9da0bfa6876613e23a5f898ebd72ea938eb1d26d9322063172bfb788be
        destination="seedvr2-runtime/$revision"
        if [ -f "$destination/inference_cli.py" ]; then exit 0; fi
        mkdir -p seedvr2-runtime
        temporary=$(mktemp -d seedvr2-runtime/download.XXXXXX)
        trap 'rm -rf "$temporary"' EXIT
        curl -fsSL --retry 2 "https://codeload.github.com/numz/ComfyUI-SeedVR2_VideoUpscaler/tar.gz/$revision" \
            -o "$temporary/source.tar.gz"
        printf '%s  %s\n' "$checksum" "$temporary/source.tar.gz" | shasum -a 256 -c
        mkdir "$temporary/runtime"
        tar -xzf "$temporary/source.tar.gz" -C "$temporary/runtime" --strip-components 1 \
            --include '*/inference_cli.py' --include '*/src/*' --include '*/configs_3b/*' \
            --include '*/pos_emb.pt' --include '*/neg_emb.pt' --include '*/LICENSE'
        test -f "$temporary/runtime/inference_cli.py"
        mv "$temporary/runtime" "$destination"
        exit 0 ;;
    *) printf 'Usage: %s [--models-only | --seedvr2-source]\n' "$0" >&2; exit 2 ;;
esac
mkdir -p models

install_model() (
    name=$1 revision=$2 checksum=$3
    target="models/$name.safetensors"
    if [ -f "$target" ] && printf '%s  %s\n' "$checksum" "$target" | shasum -a 256 -c; then
        exit 0
    fi
    temporary=$(mktemp "models/$name.XXXXXX")
    trap 'rm -f "$temporary"' EXIT
    curl -fsSL --retry 2 "https://huggingface.co/Phips/$name/resolve/$revision/$name.safetensors?download=true" -o "$temporary"
    printf '%s  %s\n' "$checksum" "$temporary" | shasum -a 256 -c
    mv "$temporary" "$target"
)

install_model 4xNomos2_hq_drct-l b2a537e13edc4c1108506df04ee0807ffc927d74 \
    1a10632101bb2aca6151301dd811921f1c438ff55159fd579fb576c143477797
install_model 4xNomos8kSCHAT-L 35fab911f23d95fcf6e34815c27f7c082567a0d5 \
    304d2d319cd75109ec1e479806d345825cd0ca580c536a2ef8b79e283e78525c
