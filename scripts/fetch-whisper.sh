#!/bin/sh
set -eu

# Source: github.com/ggml-org/whisper.cpp build instructions
WHISPER_TAG="v1.9.1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
# UNPINNED: Replace with the 64-char SHA256 computed on first download (instructions below).
# Do NOT use the 40-char HuggingFace LFS hash — it is a git LFS pointer, not a file-content SHA256.
MODEL_SHA256="<sha256-to-fill-in-on-first-download>"

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
VENDOR="$REPO_ROOT/vendor"
SRC="$VENDOR/whisper.cpp-src"

mkdir -p "$VENDOR"

# --- build whisper-cli (guarded: skip if already built) ---
if [ ! -f "$VENDOR/whisper-cli" ]; then
    git clone --depth 1 --branch "$WHISPER_TAG" \
        https://github.com/ggml-org/whisper.cpp "$SRC"
    cmake -B "$SRC/build" -S "$SRC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=ON
    cmake --build "$SRC/build" -j --config Release
    cp "$SRC/build/bin/whisper-cli" "$VENDOR/whisper-cli"
    xattr -cr "$VENDOR/whisper-cli"
    echo "whisper-cli built at $WHISPER_TAG"
fi

# --- download model (guarded: skip if already downloaded) ---
if [ ! -f "$VENDOR/ggml-small.en.bin" ]; then
    curl -L -o "$VENDOR/ggml-small.en.bin" "$MODEL_URL"
fi

# --- verify model integrity (always enforced) ---
# MODEL_SHA256 must be pinned before the model is used. On first successful download,
# this script computes the actual 64-char SHA256, prints it, and exits 1 with instructions
# to pin it. Paste the printed digest as MODEL_SHA256 above, then re-run.
if [ "$MODEL_SHA256" = "<sha256-to-fill-in-on-first-download>" ]; then
    printf 'MODEL_SHA256 is not yet pinned. Computing SHA256 of ggml-small.en.bin ...\n' >&2
    COMPUTED=$(shasum -a 256 "$VENDOR/ggml-small.en.bin" | awk '{print $1}')
    printf '\n  Computed SHA256: %s\n\n' "$COMPUTED" >&2
    printf 'Paste the above digest as MODEL_SHA256 in scripts/fetch-whisper.sh and re-run.\n' >&2
    exit 1
fi
printf '%s  %s\n' "$MODEL_SHA256" "$VENDOR/ggml-small.en.bin" | shasum -a 256 -c -
echo "ggml-small.en.bin downloaded and verified"
