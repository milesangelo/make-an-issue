#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
app_dir="$repo_root/.build/MakeAnIssue.app"
contents_dir="$app_dir/Contents"
resources_dir="$contents_dir/Resources"
plist="$contents_dir/Info.plist"
dylibs="libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib"
transcript_file=$(mktemp -t make-an-issue-smoke.XXXXXX)
trap 'rm -f "$transcript_file"' EXIT HUP INT TERM

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

require_file() {
    [ -f "$1" ] || fail "bundle structure: missing $2 ($1)"
}

[ -d "$app_dir" ] || fail "assembled app bundle not found at $app_dir; run ./scripts/fetch-whisper.sh && ./scripts/build-app.sh first"
require_file "$plist" "Info.plist"

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "com.milesangelo.make-an-issue" ] \
    || fail "bundle structure: unexpected CFBundleIdentifier"
for key in CFBundleShortVersionString CFBundleVersion; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)
    [ -n "$value" ] || fail "bundle structure: $key is empty or missing"
done
require_file "$contents_dir/MacOS/MakeAnIssue" "app executable"
[ -x "$contents_dir/MacOS/MakeAnIssue" ] || fail "bundle structure: app executable is not executable"
file "$contents_dir/MacOS/MakeAnIssue" | grep -q 'Mach-O' \
    || fail "bundle structure: app executable is not a Mach-O release binary"
for dylib in $dylibs; do
    require_file "$resources_dir/$dylib" "$dylib"
done
require_file "$resources_dir/whisper-cli" "whisper-cli"
[ -x "$resources_dir/whisper-cli" ] || fail "bundle structure: whisper-cli is not executable"
require_file "$resources_dir/ggml-small.en.bin" "ggml-small.en.bin"
pass "bundle structure and bundled whisper resources"

for macho in "$contents_dir/MacOS/MakeAnIssue" "$resources_dir/whisper-cli"; do
    if otool -l "$macho" | awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' | grep -E -q "^$repo_root/|/\.build/"; then
        fail "rpath correctness: build-tree rpath in $macho"
    fi
    if otool -L "$macho" | tail -n +2 | grep -F -q "$repo_root/.build/"; then
        fail "rpath correctness: build-tree dependency in $macho"
    fi
done
for dylib in $dylibs; do
    macho="$resources_dir/$dylib"
    if otool -l "$macho" | awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' | grep -E -q "^$repo_root/|/\.build/"; then
        fail "rpath correctness: build-tree rpath in $macho"
    fi
done
pass "Mach-O rpaths contain no build-tree paths"

if ! "$repo_root/scripts/verify-app-signing.sh" "$app_dir"; then
    fail "strict signing verification failed"
fi
pass "strict signing verification"

fixture="$repo_root/vendor/whisper.cpp-src/samples/jfk.wav"
require_file "$fixture" "vendored deterministic audio fixture"
if ! "$resources_dir/whisper-cli" -m "$resources_dir/ggml-small.en.bin" -f "$fixture" -l en -nt -t 4 >"$transcript_file" 2>&1; then
    fail "bundled ASR transcription failed"
fi
if ! grep -qi 'ask not what your country can do for you' "$transcript_file"; then
    fail "bundled ASR transcript did not contain expected JFK phrase"
fi
pass "bundled whisper-cli transcribed vendored JFK fixture"

fake_claude="$repo_root/scripts/fixtures/fake-claude"
require_file "$fake_claude" "fake claude provider fixture"
[ -x "$fake_claude" ] || fail "issue filing: fake provider is not executable"
if ! MAKE_AN_ISSUE_SMOKE_FAKE_CLAUDE="$fake_claude" MAKE_AN_ISSUE_SMOKE_TOKEN="smoke-token" \
    swift test --filter ArtifactSmokeTests/testFakeProviderFilesIssueThroughRealRunner; then
    fail "issue filing pipeline with fake provider failed"
fi
pass "real issue filing runner parsed fake issue #4242 without network"
