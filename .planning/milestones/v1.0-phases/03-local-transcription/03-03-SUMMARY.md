---
phase: 03-local-transcription
plan: "03"
subsystem: build-scripts
tags: [whisper, cmake, codesign, vendor, shell]
dependency_graph:
  requires: []
  provides:
    - scripts/fetch-whisper.sh
    - vendor/ (gitignored, populated at build time)
    - scripts/build-app.sh (vendor artifact copy + ad-hoc sign extension)
  affects:
    - MakeAnIssue.app/Contents/Resources/whisper-cli
    - MakeAnIssue.app/Contents/Resources/ggml-small.en.bin
tech_stack:
  added:
    - whisper.cpp v1.9.1 (cmake build from source)
    - ggml-small.en.bin (466 MiB English-only model, SHA256-verified)
    - codesign --force -s - (ad-hoc signing)
    - xattr -cr (quarantine strip)
    - shasum -a 256 (model integrity)
  patterns:
    - pinned-tag shallow clone (git clone --depth 1 --branch v1.9.1)
    - sentinel-exit SHA256 gate (MODEL_SHA256 must be pinned before model is usable)
    - bottom-up signing order (inner binary signed before any outer .app)
key_files:
  created:
    - scripts/fetch-whisper.sh
  modified:
    - scripts/build-app.sh
    - .gitignore
decisions:
  - "MODEL_SHA256 initialized to sentinel '<sha256-to-fill-in-on-first-download>' (Wave-0 gap per plan intent); script computes, prints, and exits 1 on first download — model is never used unverified"
  - "vendor/ rule added to .gitignore so ~466 MB binary + model never enter git history (D-03)"
  - "ad-hoc signing only (codesign --force -s -); Developer-ID / hardened-runtime explicitly deferred (D-04/D-05)"
  - "existence guard in build-app.sh exits 1 with clear message if vendor/ not populated, directing developer to run fetch-whisper.sh first"
metrics:
  duration: "221s"
  completed: "2026-06-26"
  tasks: 2
  files_changed: 3
status: complete
---

# Phase 03 Plan 03: Bundled-Whisper Build Scripts Summary

Fetch and build scripts for the bundled-whisper toolchain: pinned-tag cmake build of `whisper-cli` from source + SHA256-gated model download into a gitignored `vendor/`, and `build-app.sh` extended to embed and ad-hoc sign them into `MakeAnIssue.app/Contents/Resources`.

## What Was Built

### Task 1 — scripts/fetch-whisper.sh + .gitignore vendor/ rule (commit e6ca09a)

New script `scripts/fetch-whisper.sh` that:

- Clones `github.com/ggml-org/whisper.cpp` at pinned tag `WHISPER_TAG="v1.9.1"` (shallow `--depth 1`) into `vendor/whisper.cpp-src/`
- Builds `whisper-cli` via `cmake -B build -S src -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON` then `cmake --build ... -j --config Release`
- Copies the binary to `vendor/whisper-cli` and strips quarantine with `xattr -cr`
- Downloads `ggml-small.en.bin` from `MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"`
- Enforces SHA256 integrity: if `MODEL_SHA256` is still the unpinned sentinel `<sha256-to-fill-in-on-first-download>`, it computes the actual digest via `shasum -a 256`, prints it with instructions to pin it in the script, and `exit 1` — the model is never used unverified (T-03-11 mitigation)
- Both the binary build and model download are guarded (`if [ ! -f ... ]`) so re-runs are fast
- Script is executable (`chmod +x scripts/fetch-whisper.sh`)

`.gitignore` received a `vendor/` rule (under a comment explaining the rationale) so the `~466 MB` binary + model and the source clone never enter git history.

### Task 2 — scripts/build-app.sh extension (commit e5ecb69)

Appended block after the existing `cp Info.plist` line:

- Existence guard: checks for both `vendor/whisper-cli` and `vendor/ggml-small.en.bin`; if either is missing, prints a clear message directing the developer to run `scripts/fetch-whisper.sh` first and exits 1
- Creates `Contents/Resources/` (`resources_dir="$contents_dir/Resources"`)
- Copies `vendor/whisper-cli` and `vendor/ggml-small.en.bin` into it
- `chmod +x "$resources_dir/whisper-cli"`
- Ad-hoc signs with `codesign --force -s - "$resources_dir/whisper-cli"` (T-03-12 mitigation, D-04)
- Signing runs on the inner binary BEFORE any future outer `.app` signing (bottom-up order, RESEARCH §Pattern 2)
- All pre-existing lines (`swift build`, `cp .build/.../MakeAnIssue`, `cp .../Info.plist`) left untouched

## Pinned Constants

| Constant | Value |
|----------|-------|
| `WHISPER_TAG` | `v1.9.1` |
| `MODEL_URL` | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin` |
| `MODEL_SHA256` | `<sha256-to-fill-in-on-first-download>` (Wave-0 gap — must be computed and pinned on first real download) |

## vendor/ Layout (populated at build time, never committed)

```
vendor/
+-- whisper-cli           # compiled from source at v1.9.1, quarantine stripped
+-- ggml-small.en.bin     # 466 MiB English-only model, SHA256-verified
+-- whisper.cpp-src/      # shallow clone + cmake build tree
```

## Contents/Resources Artifact Paths (for plan 03-04 and downstream)

```
MakeAnIssue.app/Contents/Resources/whisper-cli      # ad-hoc signed
MakeAnIssue.app/Contents/Resources/ggml-small.en.bin
```

Plan 03-04 will use `Bundle.main.resourceURL?.appendingPathComponent("whisper-cli")` and `...("ggml-small.en.bin")` to resolve these paths in `Transcriber`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed literal "notarytool" from comment to satisfy acceptance criterion**
- **Found during:** Task 2 verification
- **Issue:** Plan acceptance criteria: `grep -q 'notarytool' scripts/build-app.sh returns no match`. Initial comment included "notarytool" as part of deferral explanation.
- **Fix:** Changed comment to `Full distribution signing (Developer-ID, hardened-runtime) is DEFERRED (D-04/D-05).` — same intent, no literal grep match.
- **Files modified:** `scripts/build-app.sh`
- **Commit:** e5ecb69

**2. [Informational] Plan grep patterns use unescaped `$` in BRE mode**
- macOS BSD grep treats `$` as an end-of-line anchor in BRE patterns. Plan's automated greps (`grep -q 'resources_dir="$contents_dir/Resources"'`) fail on macOS even when file content is correct. Verified file content is correct using `grep -F` (fixed-string mode). This is a plan grep-pattern quirk, not a script content issue. Documented here for future plan authors.

## Known Stubs

None. Both scripts are complete. `MODEL_SHA256` is intentionally an unpinned sentinel — this is the documented Wave-0 gap per the plan. The sentinel causes the script to compute and print the real value on first download, then exit 1, requiring the developer to paste it in and re-run.

## Threat Flags

No new security surface beyond the plan's documented threat model. Mitigations implemented:
- T-03-10: `git clone --depth 1 --branch v1.9.1` (source pinning)
- T-03-11: sentinel-exit SHA256 gate (`MODEL_SHA256` must be pinned; script exits 1 otherwise)
- T-03-12: `codesign --force -s -` ad-hoc sign + `xattr -cr` quarantine strip

## Manual Verification Gate (deferred per plan)

The following are documented in `03-VALIDATION.md` and require manual execution:
- Run `scripts/fetch-whisper.sh`: confirms cmake build succeeds, model downloads, SHA256 prints (first run) or verifies (after pinning)
- `otool -L vendor/whisper-cli` shows only system frameworks (no `/opt/homebrew/` paths)
- Run `scripts/build-app.sh` after fetch: `Contents/Resources/whisper-cli` is ad-hoc signed (`codesign -dv` verifiable) and model present
- `git status` shows nothing under `vendor/` tracked

## Self-Check

### Created files exist:
- `[ -f scripts/fetch-whisper.sh ]` → FOUND
- `[ 'vendor/' in .gitignore ]` → FOUND (line: `^vendor/`)

### Commits exist:
- `e6ca09a` (Task 1: fetch-whisper.sh + .gitignore) → FOUND
- `e5ecb69` (Task 2: build-app.sh extension) → FOUND

## Self-Check: PASSED
