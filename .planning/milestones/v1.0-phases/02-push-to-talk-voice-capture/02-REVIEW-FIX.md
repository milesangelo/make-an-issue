---
phase: 02-push-to-talk-voice-capture
fixed_at: 2026-06-24T12:03:30Z
review_path: .planning/phases/02-push-to-talk-voice-capture/02-REVIEW.md
iteration: 1
findings_in_scope: 8
fixed: 8
skipped: 0
status: all_fixed
---

# Phase 2: Code Review Fix Report

**Fixed at:** 2026-06-24T12:03:30Z
**Source review:** .planning/phases/02-push-to-talk-voice-capture/02-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 8
- Fixed: 8
- Skipped: 0

All fixes were applied in an isolated git worktree, each committed atomically.
The full test suite (38 tests) passes after all fixes.

## Fixed Issues

### CR-01: Recording failure is silently swallowed; UI/state desync to "Recording…" with no audio

**Files modified:** `Sources/MakeAnIssue/AudioRecorder.swift`, `Sources/MakeAnIssue/AppState.swift`, `Tests/MakeAnIssueTests/AppStateTests.swift`
**Commit:** 3983758
**Applied fix:** `AudioRecorder.start()` now returns `Bool` — it uses a `do/catch` instead of `try?`, logs the error via `NSLog`, and returns the result of `record()` (false if recording could not begin). The `AppState` seam `onStartRecording` is now typed `() -> Bool`, and `startRecording()` only commits the `.recording` transition when the seam reports success; on failure it stays `.idle` and sets a status message. Added `testFailedStartKeepsStateIdleAndSurfacesStatus`. Updated the existing state-machine tests to inject a succeeding seam (`{ true }`) so they exercise transitions rather than the real audio subsystem.

### CR-02: Microphone permission requested asynchronously while hotkey is live — first press records nothing

**Files modified:** `Sources/MakeAnIssue/AppState.swift`, `Tests/MakeAnIssueTests/AppStateTests.swift`
**Commit:** f779cdc
**Applied fix:** Added `@Published var micPermissionGranted`. `requestMicrophonePermission()` now returns `Bool`; the startup `Task` stores the result and surfaces a "Microphone access denied" status when not granted. `startRecording()` short-circuits (stays `.idle`, sets denied status, does not invoke the start seam) when permission is not yet granted. Added `testStartRecordingWithoutMicPermissionStaysIdleAndSurfacesStatus` and set `micPermissionGranted = true` in the existing success-path tests.
**Note:** requires human verification — gating logic and the live first-run permission race should be confirmed manually on device.

### WR-01: No AVAudioRecorderDelegate — encode errors during recording are undetectable

**Files modified:** `Sources/MakeAnIssue/AudioRecorder.swift`, `Sources/MakeAnIssue/AppState.swift`, `Tests/MakeAnIssueTests/AppStateTests.swift`
**Commit:** 9d67b4c
**Applied fix:** `AudioRecorder` conforms to `AVAudioRecorderDelegate`, sets `recorder.delegate = self` in `start()`, and implements `audioRecorderEncodeErrorDidOccur` and `audioRecorderDidFinishRecording`. Errors route through a new `onRecordingError: ((Error?) -> Void)?` closure. `AppState` wires this in its designated init, hopping to the main actor, and a new `handleRecordingError(_:)` resets the state machine and sets a status message. Added `testRecordingErrorResetsStateAndStopsRecorder`.

### WR-02: Unchecked subscript and swallowed directory-creation error in latestWavURL

**Files modified:** `Sources/MakeAnIssue/AudioRecorder.swift`, `Tests/MakeAnIssueTests/AudioRecorderTests.swift`
**Commit:** 536a761
**Applied fix:** Replaced the unchecked `[0]` with `.first` and made `outputDirectory`/`latestWavURL` optional. `start()` guards on these being non-nil (logs and returns false otherwise) and creates the directory inside the `do` block so a `createDirectory` failure is propagated rather than swallowed. Updated `AudioRecorderTests` to `XCTUnwrap` the now-optional URL.

### WR-03: Side effect (directory creation) inside a computed property accessed on every recording

**Files modified:** `Sources/MakeAnIssue/AudioRecorder.swift`
**Commit:** 3a039a2
**Applied fix:** Split path computation from directory preparation. Introduced a pure `outputDirectory` and made `latestWavURL` pure (no filesystem side effects). The `createDirectory` call now happens explicitly in `start()`. Reading the URL no longer mutates the filesystem, removing the hidden side effect the tests previously triggered.

### WR-04: Recording never finalized if stop() is not called (stuck "Recording…")

**Files modified:** `Sources/MakeAnIssue/AppState.swift`, `Sources/MakeAnIssue/MenuView.swift`, `Tests/MakeAnIssueTests/AppStateTests.swift`
**Commit:** 0f706de
**Applied fix:** Added an injectable `maxRecordingDuration` (default 120s) and a `recordingTimeoutTask`. `startRecording()` schedules a timeout; `stopRecording()` and `handleRecordingError()` cancel it. A new `recordingDidTimeout()` auto-stops and resets to `.finished` with a status message. Added a click-to-stop "Stop Recording" button in `MenuView` shown only while recording. Added `testRecordingDidTimeoutStopsRecorderAndFinishes`, `testRecordingDidTimeoutWhileIdleIsNoOp`, and an async `testRecordingAutoStopsAfterMaxDuration` (50ms duration).
**Note:** requires human verification — the timeout/cancellation concurrency and the menu-mode flapping recovery scenario should be confirmed manually.

### IN-01: audioRecorder stored on AppState but never used directly

**Files modified:** `Sources/MakeAnIssue/AppState.swift`
**Commit:** 1d99438
**Applied fix:** Added a comment documenting that the `audioRecorder` property anchors the recorder's lifetime and is now the integration point for the `onRecordingError` delegate callback (wired in init by WR-01), resolving the apparent-dead-code ambiguity.

### IN-02: Tests cover only happy paths; no failure-mode coverage

**Files modified:** `Tests/MakeAnIssueTests/AudioRecorderTests.swift`
**Commit:** c35b01a
**Applied fix:** Most failure-path coverage was added inline with CR-01/CR-02/WR-01/WR-04 (failed start, denied permission, recording error, timeout). This commit adds `testStopWithoutStartIsSafe` and `testReadingURLsHasNoFilesystemSideEffect` (verifies WR-03's purity guarantee — reading the URL does not create the directory). The real-filesystem side effect previously flagged is resolved by WR-03 making `latestWavURL` pure.

---

_Fixed: 2026-06-24T12:03:30Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
