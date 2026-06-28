---
phase: 02-push-to-talk-voice-capture
plan: "02"
subsystem: microphone-capture
tags: [audio, avfoundation, wav, microphone, tcc-permission, keyboard-shortcuts, menubar, swift]
status: complete

dependency_graph:
  requires:
    - phase: 02-01
      provides: AppState start/stop recording seam, CaptureState machine, KeyboardShortcuts.Name.pushToTalk
  provides:
    - AudioRecorder writing 16 kHz mono PCM WAV to the stable handoff path
    - NSMicrophoneUsageDescription + startup mic permission request
    - Real AudioRecorder wired into the AppState push-to-talk seam
    - MenuView capture indicator (Idle / Recording… / Done) + KeyboardShortcuts.Recorder
    - Global push-to-talk that fires regardless of focused app (verified on hardware)
  affects:
    - Sources/MakeAnIssue/AudioRecorder.swift
    - Sources/MakeAnIssue/AppState.swift
    - Sources/MakeAnIssue/MenuView.swift
    - Resources/Info.plist

tech_stack:
  added:
    - AVFoundation (AVAudioRecorder, AVAudioApplication / AVCaptureDevice permission)
  patterns:
    - TDD RED/GREEN cycle
    - Stable single-path WAV handoff with in-place overwrite (D-07)
    - Balancing NSMenu end-tracking notification to keep KeyboardShortcuts in global mode

key_files:
  created:
    - Sources/MakeAnIssue/AudioRecorder.swift
    - Tests/MakeAnIssueTests/AudioRecorderTests.swift
  modified:
    - Resources/Info.plist
    - Sources/MakeAnIssue/AppState.swift
    - Sources/MakeAnIssue/MenuView.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift

requirements-completed:
  - CAPTURE-02
  - CAPTURE-03

decisions:
  - "macOS 13 mic-permission fallback uses AVCaptureDevice.requestAccess(for:.audio) — AVAudioSession is unavailable on macOS (research-doc citation was wrong)"
  - "Push-to-talk restart guard changed from == .idle to != .recording so a new press records again from .finished (state machine had no edge back to idle)"
  - "Post NSMenu.didEndTrackingNotification on menu close to leave KeyboardShortcuts' focus-only .menuOpen mode and resume the global Carbon hotkey"

metrics:
  duration: "post-checkpoint debug + fix cycle"
  completed: "2026-06-24"
  tasks_completed: 4
  tasks_total: 4
  files_modified: 6
---

# Phase 02 Plan 02: Microphone Capture & Permission Summary

**One-liner:** Real 16 kHz mono PCM WAV capture wired into the push-to-talk seam with a startup mic-permission prompt and menu indicator; a blocking human-verify checkpoint surfaced two defects (a stuck capture state machine and a focus-only global hotkey) that were fixed and re-verified on hardware.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add NSMicrophoneUsageDescription to Info.plist | 719c031 | Resources/Info.plist |
| 2 (RED) | Failing AudioRecorder tests | 3778c08 | Tests/MakeAnIssueTests/AudioRecorderTests.swift |
| 2 (GREEN) | AudioRecorder 16 kHz mono WAV writer | 6e02176 | Sources/MakeAnIssue/AudioRecorder.swift |
| 3 | Wire AudioRecorder + mic permission into AppState; MenuView indicator + Recorder | 9481047 | Sources/MakeAnIssue/AppState.swift, Sources/MakeAnIssue/MenuView.swift |
| 4 | Human-verify checkpoint (mic permission, background hotkey, real WAV) | — | (verified on hardware — see below) |

### Post-checkpoint fixes (defects found during human verification)

| Fix | Commit | Files |
|------|--------|-------|
| RED: failing tests for re-recording after a completed cycle | 1b5ac9b | Tests/MakeAnIssueTests/AppStateTests.swift |
| GREEN: allow push-to-talk to restart from `.finished` | 0b0e8f9 | Sources/MakeAnIssue/AppState.swift |
| Keep global hotkey active after the menu closes | d1899c6 | Sources/MakeAnIssue/MenuView.swift |

## What Was Built

**Resources/Info.plist** — `NSMicrophoneUsageDescription` ("Make an Issue records your voice to create GitHub issues.") so the macOS TCC prompt can appear.

**AudioRecorder.swift** (new) — Writes a 16 kHz mono PCM WAV via `AVAudioRecorder` to the stable handoff path `~/Library/Application Support/MakeAnIssue/latest.wav`, overwriting in place (D-07, D-08, D-09).

**AppState.swift** — Real `AudioRecorder` injected into the start/stop seam from Plan 02-01; microphone permission requested at startup (`AVAudioApplication.requestRecordPermission()` on macOS 14+, `AVCaptureDevice.requestAccess(for: .audio)` on macOS 13).

**MenuView.swift** — Capture indicator (Idle / Recording… / Done) and a `KeyboardShortcuts.Recorder` to reconfigure the shortcut.

## Human-Verify Checkpoint (Task 4)

The blocking checkpoint was tested against real hardware. The first round **failed Step 1** (background hotkey did not trigger while another app was focused), which drove a systematic root-cause investigation:

- **Confirmed via filesystem evidence:** on a fresh launch where the menu was never opened, the global Carbon hotkey fired correctly while Terminal was focused (fresh `latest.wav` written).
- **Root cause:** KeyboardShortcuts pauses its global Carbon hotkey and falls back to a focus-only `RunLoopLocalEventMonitor` whenever it believes a menu is open (`HotKey` `.menuOpen` mode). Opening the `MenuBarExtra` window fired `NSMenu.didBeginTracking` with no balanced `didEndTracking` on close, so `isMenuOpen` stuck `true` and push-to-talk stopped working globally.
- **Second defect found:** the capture state machine had no edge back to `.idle`, so `startRecording()`'s `guard == .idle` blocked every press after the first complete cycle.

After both fixes, the human re-verified and **approved**: global push-to-talk works after opening/closing the menu, recording works on every press (not just the first), and the WAV is real 16 kHz mono PCM.

## Verification Results

```
swift build → exit 0, Build complete!
swift test  → 30 tests, 0 failures   (was 28; +2 re-recording tests)
Human hardware verification (Task 4 checkpoint) → APPROVED
  - background hotkey fires while another app is focused (after menu open/close)
  - second consecutive recording works (state machine reset)
  - file/afinfo confirm RIFF WAVE, 16000 Hz, 1 channel, 16-bit
```

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| `AVCaptureDevice.requestAccess` for macOS 13 mic permission | `AVAudioSession` is unavailable on macOS; the research doc's citation was wrong (auto-fixed, Rule 1) |
| `startRecording()` guard `!= .recording` (was `== .idle`) | The `.finished` state had no path back to `.idle`; the new guard records again on the next press while still ignoring key repeats (D-04) |
| Post `NSMenu.didEndTrackingNotification` on menu close | Re-asserts KeyboardShortcuts `.normal` mode so the global Carbon hotkey resumes after the MenuBarExtra window's unbalanced begin-tracking |

## Deviations from Plan

### macOS 13 permission API (Task 3)
**Issue:** Plan/research cited `AVAudioSession.sharedInstance()` as the macOS 13 fallback, but `AVAudioSession` is marked unavailable on macOS.
**Fix:** Used `AVCaptureDevice.requestAccess(for: .audio)` (available on macOS 13+). Type: Rule 1 (compilation error).

### Two defects fixed after the checkpoint
The blocking human-verify checkpoint did its job — it caught a stuck state machine and a focus-only global hotkey that no headless test could surface. Both were root-caused, fixed with TDD where testable, and re-verified on hardware.

## Threat Flags

None new. Microphone access is gated by the standard macOS TCC prompt (`NSMicrophoneUsageDescription`). KeyboardShortcuts uses Carbon `RegisterEventHotKey` (no Accessibility permission). WAV is written only to the app's own Application Support directory.

## Self-Check: PASSED

- [x] AudioRecorder.swift created — exists
- [x] AudioRecorderTests.swift created — exists
- [x] Info.plist, AppState.swift, MenuView.swift, AppStateTests.swift modified — exist
- [x] Commits 719c031, 3778c08, 6e02176, 9481047, 1b5ac9b, 0b0e8f9, d1899c6 — verified in git log
- [x] 30 tests pass, 0 failures
- [x] Task 4 human-verify checkpoint APPROVED on hardware (CAPTURE-02, CAPTURE-03)
