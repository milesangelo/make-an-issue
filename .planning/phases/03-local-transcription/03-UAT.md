---
status: testing
phase: 03-local-transcription
source: [03-VERIFICATION.md]
started: "2026-06-26T03:49:20Z"
updated: "2026-06-26T03:49:20Z"
---

## Current Test

number: 1
name: Assembled .app end-to-end smoke (SC1 + SC2)
expected: |
  Bundled whisper-cli produces a transcript visible in the TranscriptCard and in
  Console.app NSLog. Menu shows Transcribing... then Done. No ASR Command field in
  Settings — only Push-to-Talk Shortcut and CLI Command.
awaiting: user response

## Tests

### 1. Assembled .app end-to-end smoke (SC1 + SC2)
expected: Run `scripts/fetch-whisper.sh` then `scripts/build-app.sh`; launch the assembled `MakeAnIssue.app`; hold the push-to-talk shortcut, speak a phrase, release. Bundled whisper-cli produces a transcript visible in the TranscriptCard and in Console.app NSLog. Menu shows Transcribing... then Done. No ASR Command field in Settings — only Push-to-Talk Shortcut and CLI Command.
result: [pending]

### 2. Gatekeeper check (SC3)
expected: After `scripts/build-app.sh`, `codesign -dv Contents/Resources/whisper-cli` shows an ad-hoc signature; launching the assembled `.app` and triggering transcription produces no "cannot be opened" Gatekeeper dialog; whisper-cli executes and produces a transcript.
result: [pending]

### 3. scripts/fetch-whisper.sh full run (Wave-0 gap: cmake build + model download + SHA256 pinning)
expected: `vendor/whisper-cli` built at v1.9.1; `vendor/ggml-small.en.bin` downloaded; on first run the script prints the computed SHA256 and exits 1 with instructions to pin it; after pinning `MODEL_SHA256`, a re-run verifies the checksum and exits 0. `otool -L vendor/whisper-cli` shows no `/opt/homebrew/` paths.
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
