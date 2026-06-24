---
status: testing
phase: 03-local-transcription
source: [03-VERIFICATION.md]
started: "2026-06-24T21:21:13Z"
updated: "2026-06-24T21:21:13Z"
---

## Current Test

number: 1
name: Live push-to-talk with real ASR binary
expected: |
  Menu transitions "Recording..." → "Transcribing..." → "Done". The transcript
  text appears in the selectable menu block. Console.app shows
  `MakeAnIssue transcript: <spoken text>` from NSLog.
awaiting: user response

## Tests

### 1. Live push-to-talk with real ASR binary
expected: Install a local ASR tool (e.g. `whisper`) on the login-shell PATH. Enter a command (e.g. `whisper {wav} --model base.en`) in the ASR Command field. Hold the push-to-talk shortcut, speak, release. Menu transitions "Recording..." → "Transcribing..." → "Done"; transcript appears in the selectable menu block; Console.app shows `MakeAnIssue transcript: <spoken text>`.
result: [pending]

### 2. Empty ASR command at runtime
expected: Leave the ASR Command field blank. Hold and release push-to-talk. No process is spawned. Menu shows a "set your ASR command" message. State returns to idle so a new push-to-talk attempt works.
result: [pending]

### 3. ASR command without {wav} token
expected: Enter a command without `{wav}` (e.g. `whisper --model base`). Hold and release push-to-talk. Menu shows an error mentioning `{wav}` is required. No process is spawned. State resets to idle.
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
