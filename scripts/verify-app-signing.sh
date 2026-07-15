#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
app_dir="${1:-$repo_root/.build/MakeAnIssue.app}"

if [ ! -d "$app_dir" ]; then
    echo "ERROR: app bundle not found: $app_dir" >&2
    exit 1
fi

# This validates the sealed bundle and all nested code. `spctl --assess` is
# deliberately not run here: an ad-hoc signature is valid but not Gatekeeper-
# approved. Developer ID signing and notarization are separate release work.
codesign --verify --deep --strict --verbose=2 "$app_dir"
