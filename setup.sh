#!/bin/sh
set -eu
cd "$(dirname "$0")"

case "${1:-}" in
    "") uv sync --locked --python 3.12
        mkdir -p input output ;;
    --models-only) ;;
    *) printf 'Usage: %s [--models-only]\n' "$0" >&2; exit 2 ;;
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
