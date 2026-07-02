---
phase: 03-local-transcription
plan: "05"
subsystem: build-scripts
tags: [gap-closure, dylib-bundling, rpath, codesign, sha256]
dependency_graph:
  requires: [03-03-PLAN, 03-04-PLAN]
  provides: [self-contained-app-bundle, pinned-model-checksum]
  affects: [scripts/fetch-whisper.sh, scripts/build-app.sh]
tech_stack:
  added: []
  patterns: [install_name_tool rpath rewriting, bottom-up ad-hoc codesign, dylib vendoring]
key_files:
  created: []
  modified:
    - scripts/fetch-whisper.sh
    - scripts/build-app.sh
decisions:
  - "MODEL_SHA256 pinned to content digest c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d (UAT GAP 2 closed)"
  - "Dylib list defined once as DYLIBS shell variable; reused in both scripts for DRY guard and copy logic"
  - "install_name_tool reads LC_RPATH dynamically from binary via otool/awk rather than hardcoding home path"
  - "Dylib signing guard runs independently of whisper-cli build guard in fetch-whisper.sh (idempotent)"
metrics:
  duration: "99s"
  completed: "2026-06-26"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 2
status: complete
---

# Phase 03 Plan 05: Gap Closure (Self-Contained .app + SHA Pin) Summary

**One-liner:** Pinned model SHA256 and bundled six @rpath dylibs with @loader_path rpath rewrite, closing the two UAT-diagnosed gaps that prevented the .app from running without the build tree.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | fetch-whisper.sh — pin MODEL_SHA256 + vendor six @rpath dylibs | 56c2e3c | scripts/fetch-whisper.sh |
| 2 | build-app.sh — bundle dylibs, rewrite LC_RPATH to @loader_path, sign bottom-up | 2691bf5 | scripts/build-app.sh |

## What Was Built

### Task 1: fetch-whisper.sh (GAP 2 + GAP 1a)

**EDIT A — Model digest pin (GAP 2):**
- Replaced `MODEL_SHA256="<sha256-to-fill-in-on-first-download>"` with the real 64-char content digest `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d`
- Updated the stale "UNPINNED: Replace with..." comment to read "Pinned 64-char content SHA256 of ggml-small.en.bin"
- Preserved the sentinel-gating comparison and the `shasum -a 256 -c -` verify path unchanged

**EDIT B — Dylib vendoring (GAP 1a):**
- Added guarded block that copies the six `@rpath` basenames (`libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib`) from `$SRC/build/bin/` into `$VENDOR/`
- Guard checks all six are present; runs independently of the whisper-cli build guard
- `cp` dereferences the build-tree symlinks, producing flat real Mach-O files named as @rpath basenames
- Runs `xattr -cr` on each, matching existing whisper-cli handling
- Fails fast with rm-and-rerun message if `build/bin` is absent but dylibs are missing

### Task 2: build-app.sh (GAP 1b)

1. **Extended preflight guard** — `DYLIBS` variable defined once; for-loop exits 1 with `fetch-whisper.sh` hint if any of the six dylibs is missing from `vendor/`

2. **Dylib copy to Resources** — loop copies each vendored dylib into `$resources_dir/` alongside whisper-cli so `@loader_path` resolves them at runtime

3. **LC_RPATH rewrite** — `otool -l` extracts the current absolute rpath dynamically (no hardcoded home path); `install_name_tool -delete_rpath` removes it then `-add_rpath @loader_path` is added unconditionally; this runs before codesign (install_name_tool invalidates existing signatures)

4. **Bottom-up signing** — each dylib is ad-hoc signed (`codesign --force -s -`) before whisper-cli is signed last

## Verification Results

**Task 1 verification passed:**
- `grep -Eq '^MODEL_SHA256="c6138d..."$'` matched
- `sh -n scripts/fetch-whisper.sh` parsed clean
- `scripts/fetch-whisper.sh` re-ran; model checksum verified ("ggml-small.en.bin downloaded and verified")
- All six `vendor/lib*.dylib` confirmed as real Mach-O files (not symlinks)

**Task 2 verification passed:**
- `scripts/build-app.sh` ran cleanly (swift build: 0.64s)
- All six `Contents/Resources/lib*.dylib` present and `codesign -v` clean
- `otool -l` shows `@loader_path` rpath on bundled whisper-cli
- No absolute `build/bin` rpath remaining
- **Self-containment proof:** copied whisper-cli + model + all six dylibs to a temp dir with no build tree accessible; ran `whisper-cli -m ggml-small.en.bin -f jfk.wav -l en -nt -t 4`; output contained "country"; exit 0 — **GAP 1 fully closed**

## Deviations from Plan

None — plan executed exactly as written.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced.
- T-03-01 (Tampering/model download): Mitigated — MODEL_SHA256 now pinned; `shasum -a 256 -c -` enforced on every run.
- T-03-02 (Tampering/build source): Mitigated — whisper-cli loads only bundled ad-hoc-signed dylibs via @loader_path; no absolute build-tree rpath remains.
- T-03-03 (Elevation): Accepted — ad-hoc signed; Developer-ID + hardened-runtime notarization deferred (D-04/D-05).

## Self-Check: PASSED

- [x] `scripts/fetch-whisper.sh` — exists and modified
- [x] `scripts/build-app.sh` — exists and modified
- [x] Task 1 commit 56c2e3c — exists in git log
- [x] Task 2 commit 2691bf5 — exists in git log
- [x] Self-containment proof ran successfully (TASK2 OK SELF-CONTAINED)
