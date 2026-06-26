#!/bin/sh
set -eu

# Source: github.com/ggml-org/whisper.cpp build instructions
WHISPER_TAG="v1.9.1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
# Pinned 64-char content SHA256 of ggml-small.en.bin.
# Do NOT use the 40-char HuggingFace LFS hash — it is a git LFS pointer, not a file-content SHA256.
MODEL_SHA256="c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"

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

# --- vendor dylibs (guarded: skip if all six already present) ---
# These are the exact @rpath basenames whisper-cli links. Copying from build/bin dereferences
# the symlinks, producing flat real Mach-O files named as the @rpath basenames.
DYLIBS="libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib"
_need_dylibs=0
for _lib in $DYLIBS; do
    [ -f "$VENDOR/$_lib" ] || _need_dylibs=1
done
if [ "$_need_dylibs" -eq 1 ]; then
    if [ ! -d "$SRC/build/bin" ]; then
        echo "ERROR: $SRC/build/bin not found but dylibs are missing from vendor/." >&2
        echo "Remove vendor/whisper-cli and the source tree, then re-run:" >&2
        echo "  rm -rf \"$VENDOR/whisper-cli\" \"$SRC\"" >&2
        exit 1
    fi
    for _lib in $DYLIBS; do
        cp "$SRC/build/bin/$_lib" "$VENDOR/$_lib"
        xattr -cr "$VENDOR/$_lib"
    done
    echo "Vendored dylibs: $DYLIBS"
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
