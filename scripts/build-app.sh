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
