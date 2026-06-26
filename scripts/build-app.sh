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
if [ ! -f "$repo_root/vendor/whisper-cli" ] || [ ! -f "$repo_root/vendor/ggml-small.en.bin" ]; then
    echo "ERROR: vendor/whisper-cli or vendor/ggml-small.en.bin not found." >&2
    echo "Run scripts/fetch-whisper.sh first." >&2
    exit 1
fi

resources_dir="$contents_dir/Resources"
mkdir -p "$resources_dir"
cp "$repo_root/vendor/whisper-cli" "$resources_dir/whisper-cli"
cp "$repo_root/vendor/ggml-small.en.bin" "$resources_dir/ggml-small.en.bin"
chmod +x "$resources_dir/whisper-cli"

# Ad-hoc sign whisper-cli BEFORE signing the .app (bottom-up order).
# Full distribution signing (Developer-ID, hardened-runtime) is DEFERRED (D-04/D-05).
codesign --force -s - "$resources_dir/whisper-cli"
