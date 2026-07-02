---
status: complete
phase: 02-push-to-talk-voice-capture
source:
  - 02-01-SUMMARY.md
  - 02-02-SUMMARY.md
started: 2026-06-24T18:12:43Z
updated: 2026-06-24T18:15:00Z
---

## Current Test

[testing complete]

## Tests

### 1. Microphone Permission Prompt
expected: On a fresh launch, macOS shows a mic-permission prompt reading "Make an Issue records your voice to create GitHub issues." Granting it lets the app record. (If already granted, no prompt — still a pass.)
result: pass

### 2. Push-to-Talk Starts Recording
expected: Press and hold the shortcut (default Control-Option-I). Open the menu — the capture indicator shows "Recording…".
result: pass

### 3. Release Stops Recording
expected: Release the keys. The menu capture indicator changes to "Done" (and returns to "Idle" on the next idle state).
result: pass

### 4. Global Hotkey While Another App Is Focused
expected: Focus a different app (e.g. Terminal or Safari), then press the shortcut. Recording still fires even though Make an Issue is not the front app — including after you've opened and closed the menu at least once.
result: pass

### 5. Repeat Recording
expected: After completing one full record cycle, press the shortcut again. Recording starts again on the second (and every subsequent) press — it is not blocked after the first cycle.
result: pass

### 6. WAV File Written Correctly
expected: After a recording, `~/Library/Application Support/MakeAnIssue/latest.wav` exists. Running `afinfo` on it reports RIFF/WAVE, 16000 Hz, 1 channel (mono), 16-bit. Each new recording overwrites the same file in place.
result: pass

### 7. Reconfigure Shortcut From Menu
expected: Open the menu and use the shortcut recorder control to set a new key combo. The newly chosen shortcut then triggers recording (and the old one no longer does).
result: pass

## Summary

total: 7
passed: 7
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

[none yet]
