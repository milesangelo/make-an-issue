---
status: testing
phase: 07-appkit-status-item-ui-settings-window-shell
source: [07-VERIFICATION.md]
started: "2026-06-30T19:14:38Z"
updated: "2026-06-30T19:14:38Z"
---

## Current Test

number: 1
name: Right-click / Control-click the menu-bar icon (macOS 13, 14, 15)
expected: |
  Menu with exactly two items: "Settings…" and "Quit" (separated by a divider);
  no app-name header or extra rows.
awaiting: user response

## Tests

### 1. Right-click / Control-click the menu-bar icon (macOS 13, 14, 15)
expected: Menu with exactly two items — "Settings…" and "Quit" — separated by a divider; no app-name header or extra rows.
result: [pending]

### 2. Left-click the menu-bar icon (macOS 13, 14, 15)
expected: Status popover opens showing MenuView content (header, RepositoryCard, ActionCard, etc.).
result: [pending]

### 3. Choose Settings… then click the Recorder and press a key combination
expected: The Settings window opens and takes keyboard focus (no macOS "beep" denying focus); the Recorder captures the key press. Choosing Settings… again raises the existing window — no second window spawns.
result: [pending]

### 4. Hold push-to-talk while watching the menu-bar icon; release; then trigger transcription
expected: Menu-bar icon background turns red (semi-transparent) while recording; reverts the instant the shortcut is released. No red tint during transcribing or filing. If the tint is absent on macOS 13, apply the button-layer fallback from 07-01-SUMMARY.md (Open Question 1) and re-UAT.
result: [pending]

### 5. Choose Quit from the right-click menu with an in-flight filing active
expected: App exits cleanly; `pgrep -f claude` and `docker ps` show no orphaned processes or containers.
result: [pending]

### 6. Push-to-talk survival across popover/menu cycles (Finder focused)
expected: With Finder focused — (a) open then close the popover via left-click, then press the shortcut; (b) open then close the right-click menu, then press the shortcut; (c) press the shortcut while the popover is open. Recording begins each time — no lockout from unbalanced menu-tracking state.
result: [pending]

## Summary

total: 6
passed: 0
issues: 0
pending: 6
skipped: 0
blocked: 0

## Gaps
