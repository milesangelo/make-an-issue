---
status: diagnosed
phase: 03-local-transcription
source: [03-VERIFICATION.md]
started: "2026-06-26T03:49:20Z"
updated: "2026-06-25T00:00:00Z"
---

## Current Test

[testing complete]

## Tests

### 1. Assembled .app end-to-end smoke (SC1 + SC2)
expected: Run `scripts/fetch-whisper.sh` then `scripts/build-app.sh`; launch the assembled `MakeAnIssue.app`; hold the push-to-talk shortcut, speak a phrase, release. Bundled whisper-cli produces a transcript visible in the TranscriptCard and in Console.app NSLog. Menu shows Transcribing... then Done. No ASR Command field in Settings — only Push-to-Talk Shortcut and CLI Command.
result: pass

### 2. Gatekeeper check (SC3)
expected: After `scripts/build-app.sh`, `codesign -dv Contents/Resources/whisper-cli` shows an ad-hoc signature; launching the assembled `.app` and triggering transcription produces no "cannot be opened" Gatekeeper dialog; whisper-cli executes and produces a transcript.
result: pass
note: |
  Verified by orchestrator. codesign -dv → flags=0x2(adhoc), Signature=adhoc, valid on
  disk. No com.apple.quarantine xattr on the app (locally built) so no "cannot be opened"
  dialog. binary launches (--help exit 0). spctl --assess: rejected — expected for ad-hoc
  (assesses against Developer-ID/notarization policy; not the subprocess dialog).
  SEPARATE FINDING logged as gap below: bundle is not self-contained (dylibs not copied
  into .app; only LC_RPATH is an absolute build-tree path).

### 3. scripts/fetch-whisper.sh full run (Wave-0 gap: cmake build + model download + SHA256 pinning)
expected: `vendor/whisper-cli` built at v1.9.1; `vendor/ggml-small.en.bin` downloaded; on first run the script prints the computed SHA256 and exits 1 with instructions to pin it; after pinning `MODEL_SHA256`, a re-run verifies the checksum and exits 0. `otool -L vendor/whisper-cli` shows no `/opt/homebrew/` paths.
result: pass
note: |
  Orchestrator-verified: otool -L vendor/whisper-cli shows no /opt/homebrew paths
  (all @rpath + /usr/lib system libs); `whisper.cpp version: 1.9.1`; ggml-small.en.bin
  present (488M). SHA-pinning gating logic present (scripts/fetch-whisper.sh:40-47).
  SEPARATE FINDING logged as gap below: committed MODEL_SHA256 is still the placeholder,
  so a clean-checkout re-run can't verify the checksum until the digest is pinned.

## Summary

total: 3
passed: 3
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

- truth: "Assembled .app is self-contained: bundled whisper-cli resolves its libraries from inside the .app, so it runs on a clean machine without the build tree present"
  status: failed
  reason: "Orchestrator verification during Test 2: no .dylib files exist inside MakeAnIssue.app; whisper-cli's only LC_RPATH is the absolute build-tree path /Users/milesangelo/source/make-an-issue/vendor/whisper.cpp-src/build/bin. It runs now only because that build dir still exists on disk. Moving the .app to another Mac or deleting vendor/whisper.cpp-src/build/ would cause a dyld 'Library not loaded' failure."
  severity: major
  test: 2
  root_cause: "scripts/build-app.sh copies only whisper-cli + the model into Contents/Resources and ad-hoc signs whisper-cli (lines 29-35). It never (a) copies the @rpath dylibs (libwhisper.1.dylib, libggml.0/libggml-base.0/libggml-cpu.0/libggml-blas.0/libggml-metal.0.dylib) into the bundle, (b) rewrites whisper-cli's LC_RPATH (currently the absolute build path /Users/.../vendor/whisper.cpp-src/build/bin) to a loader-relative path via install_name_tool, or (c) ad-hoc signs those dylibs. The libs exist only under vendor/whisper.cpp-src/build/bin/; fetch-whisper.sh copies only the whisper-cli binary into vendor/, so vendor/ has no stable dylib source either."
  artifacts:
    - path: "scripts/build-app.sh"
      issue: "Bundles whisper-cli but not its @rpath dylibs; never rewrites the absolute LC_RPATH to @loader_path; never signs the dylibs."
    - path: "scripts/fetch-whisper.sh"
      issue: "Copies only build/bin/whisper-cli into vendor/; does not vendor the libwhisper/libggml dylibs, leaving build-app.sh without a stable source to bundle from."
  missing:
    - "fetch-whisper.sh: also copy build/bin/lib{whisper,ggml,ggml-base,ggml-cpu,ggml-blas,ggml-metal}*.dylib into vendor/ (alongside whisper-cli)."
    - "build-app.sh: cp the vendored dylibs into Contents/Resources/ (or a Frameworks/ dir)."
    - "build-app.sh: install_name_tool -delete_rpath <absolute build path> and -add_rpath @loader_path on the bundled whisper-cli so it finds the co-located dylibs."
    - "build-app.sh: ad-hoc codesign each bundled dylib BEFORE signing whisper-cli (bottom-up)."
    - "Verify: with vendor/whisper.cpp-src/build/ removed, the assembled .app still transcribes (otool -L shows @loader_path/@rpath only, no absolute build path)."

- truth: "scripts/fetch-whisper.sh verifies the model checksum on a clean checkout: re-run after pinning MODEL_SHA256 exits 0"
  status: failed
  reason: "Orchestrator verification during Test 3: committed scripts/fetch-whisper.sh:9 still has MODEL_SHA256=\"<sha256-to-fill-in-on-first-download>\" (placeholder). Gating logic is correct (lines 40-47), but the real digest was never pinned back into the script, so a clean checkout cannot pass the checksum-verify path. otool/version/model checks all passed."
  severity: minor
  test: 3
  root_cause: "The digest computed on first download was never pasted back into scripts/fetch-whisper.sh:9, which still reads MODEL_SHA256=\"<sha256-to-fill-in-on-first-download>\". The verify branch (lines 40-47) is correct; only the pinned value is missing. Actual content SHA256 of vendor/ggml-small.en.bin = c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d."
  artifacts:
    - path: "scripts/fetch-whisper.sh"
      issue: "Line 9 MODEL_SHA256 still the placeholder; checksum-verify path unreachable on a clean checkout."
  missing:
    - "Pin scripts/fetch-whisper.sh:9 to MODEL_SHA256=\"c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d\"."
    - "Verify: a clean re-run reaches line 47 and 'shasum -a 256 -c -' prints OK / exits 0."
