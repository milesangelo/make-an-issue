#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
app_dir="$repo_root/.build/MakeAnIssue.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

cd "$repo_root"

swift build

rm -rf "$app_dir"
mkdir -p "$macos_dir"

cp "$repo_root/.build/debug/MakeAnIssue" "$macos_dir/MakeAnIssue"
cp "$repo_root/Resources/Info.plist" "$contents_dir/Info.plist"

# Copy vendor artifacts into Contents/Resources and ad-hoc sign whisper-cli.
# Run scripts/fetch-whisper.sh first to populate vendor/.
DYLIBS="libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib"

if [ ! -f "$repo_root/vendor/whisper-cli" ] || [ ! -f "$repo_root/vendor/ggml-small.en.bin" ]; then
    echo "ERROR: vendor/whisper-cli or vendor/ggml-small.en.bin not found." >&2
    echo "Run scripts/fetch-whisper.sh first." >&2
    exit 1
fi
for _lib in $DYLIBS; do
    if [ ! -f "$repo_root/vendor/$_lib" ]; then
        echo "ERROR: vendor/$_lib not found." >&2
        echo "Run scripts/fetch-whisper.sh first." >&2
        exit 1
    fi
done

resources_dir="$contents_dir/Resources"
mkdir -p "$resources_dir"
cp "$repo_root/vendor/whisper-cli" "$resources_dir/whisper-cli"
cp "$repo_root/vendor/ggml-small.en.bin" "$resources_dir/ggml-small.en.bin"
chmod +x "$resources_dir/whisper-cli"

# Copy vendored dylibs into Resources so @loader_path resolves them at runtime
for _lib in $DYLIBS; do
    cp "$repo_root/vendor/$_lib" "$resources_dir/$_lib"
done

# Rewrite whisper-cli's absolute LC_RPATH to @loader_path (must precede codesign).
# install_name_tool invalidates any existing signature, so this runs before codesign.
_old_rpath=$(otool -l "$resources_dir/whisper-cli" | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; exit}')
if [ -n "$_old_rpath" ] && [ "$_old_rpath" != "@loader_path" ]; then
    install_name_tool -delete_rpath "$_old_rpath" "$resources_dir/whisper-cli"
fi
install_name_tool -add_rpath "@loader_path" "$resources_dir/whisper-cli"

# Ad-hoc sign dylibs bottom-up FIRST, then whisper-cli last.
# Full distribution signing (Developer-ID, hardened-runtime) is DEFERRED (D-04/D-05).
for _lib in $DYLIBS; do
    codesign --force -s - "$resources_dir/$_lib"
done
codesign --force -s - "$resources_dir/whisper-cli"
