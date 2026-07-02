---
phase: 02-push-to-talk-voice-capture
verified: 2026-06-24T11:40:00Z
status: passed
score: 9/9 must-haves verified
behavior_unverified: 0
overrides_applied: 0
---

# Phase 02: Push-to-Talk Voice Capture — Verification Report

**Phase Goal:** A user-configurable global shortcut records microphone audio while held and writes an ASR-ready WAV on release.
**Verified:** 2026-06-24T11:40:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Global push-to-talk shortcut registered at startup via KeyboardShortcuts, default Control-Option-I, user-reconfigurable (CAPTURE-01) | VERIFIED | `AppState.swift` L12-14: `extension KeyboardShortcuts.Name { static let pushToTalk = Self("pushToTalk", initial: .init(.i, modifiers: [.control, .option])) }`. Registered in `init` at L65-76, not in a View. `MenuView.swift` L29: `KeyboardShortcuts.Recorder("Push-to-Talk:", name: .pushToTalk)` provides reconfiguration. Hardware-verified: fires while Terminal is focused. |
| 2 | Holding shortcut starts recording state; releasing it stops it; menu reflects Idle/Recording…/Done (CAPTURE-02) | VERIFIED | `AppState.swift` L65-76: `onKeyDown` calls `startRecording()`, `onKeyUp` calls `stopRecording()`. `MenuView.swift` L27, L45-51: `captureStateLabel` maps `.idle`→"Idle", `.recording`→"Recording…", `.finished`→"Done". `LabeledContent("Recording", value: captureStateLabel)` renders it. Hardware-verified: hold/release cycle works on every press. |
| 3 | Repeated key-down while already recording is ignored — capture state stays `.recording` (D-04) | VERIFIED | `AppState.swift` L97: `guard captureState != .recording else { return }`. `AppStateTests.swift` L84-90: `testSecondStartRecordingWhileRecordingIsIgnored` passes. Named test run confirmed exit 0. |
| 4 | Releasing the held shortcut produces a real 16 kHz mono PCM WAV at the stable handoff path under Application Support/MakeAnIssue/latest.wav (CAPTURE-03) | VERIFIED | `AudioRecorder.swift` L20-28: `wavSettings` sets `AVFormatIDKey: Int(kAudioFormatLinearPCM)`, `AVSampleRateKey: 16_000.0`, `AVNumberOfChannelsKey: 1`, `AVLinearPCMBitDepthKey: 16`. `latestWavURL` resolves to `applicationSupportDirectory/MakeAnIssue/latest.wav` (L12-16). Hardware-verified: `file`/`afinfo` confirmed RIFF WAVE, 16000 Hz, 1 channel, 16-bit. |
| 5 | Recordings are written under Application Support/MakeAnIssue, never inside the bound repo (D-06) | VERIFIED | `AudioRecorder.swift` L12-16: path built exclusively from `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` + hardcoded `"MakeAnIssue"` + `"latest.wav"` — no user-controlled path component. |
| 6 | Each new recording overwrites the prior one in place — no timestamped history (D-07) | VERIFIED | `AudioRecorder.swift` L31-33: `AVAudioRecorder(url: latestWavURL, settings: Self.wavSettings)` targets the same URL on every `start()` call. No date/UUID appended. Hardware-verified: second recording updated modification time of same file with no sibling files created. |
| 7 | AppState exposes an observable capture state the menu can read (idle/recording/finished) | VERIFIED | `AppState.swift` L22: `@Published var captureState: CaptureState = .idle`. `MenuView.swift` L46: `switch appState.captureState` — state read from EnvironmentObject. `AppStateTests.swift` L71-143: 9 state-machine tests, all passing. |
| 8 | Microphone permission is requested before the first recording so the TCC dialog appears instead of silently producing an empty file | VERIFIED | `AppState.swift` L79-91: `Task { await AppState.requestMicrophonePermission() }` in `init`. `requestMicrophonePermission` uses `#available(macOS 14, *)` branch with `AVAudioApplication.requestRecordPermission()`, falling back to `AVCaptureDevice.requestAccess(for: .audio)` on macOS 13. `Resources/Info.plist` L25-26: `NSMicrophoneUsageDescription` present; `plutil -lint` confirmed OK. Hardware-verified: TCC dialog appeared on first launch. |
| 9 | The global hotkey remains in global Carbon mode after the MenuBarExtra window is opened and closed | VERIFIED | `MenuView.swift` L33-42: `.onDisappear` posts `NSMenu.didEndTrackingNotification` to counterbalance KeyboardShortcuts' `.menuOpen` mode that gets stuck on menu close. Hardware-verified: hotkey fires while Terminal is focused after opening/closing the menu. |

**Score:** 9/9 truths verified (0 present-behavior-unverified)

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Package.swift` | KeyboardShortcuts SPM dependency wired into MakeAnIssue target | VERIFIED | `sindresorhus/KeyboardShortcuts` `from: "3.0.1"` present; `.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")` in target dependencies. `swift build` exits 0. |
| `Sources/MakeAnIssue/AppState.swift` | CaptureState enum, captureState @Published, pushToTalk Name, onKeyDown/onKeyUp, startRecording/stopRecording, AudioRecorder wiring, mic permission | VERIFIED | All symbols present and substantive (L6-10 enum, L12-14 Name extension, L22 @Published, L65-76 shortcut registration, L93-106 methods, L24 audioRecorder property, L84-91 permission request). Not a stub. |
| `Sources/MakeAnIssue/AudioRecorder.swift` | AVAudioRecorder wrapper writing 16 kHz mono PCM WAV to latest.wav, wavSettings, latestWavURL | VERIFIED | File created (41 lines). `final class AudioRecorder: NSObject`. `latestWavURL` (L11-17), `wavSettings` (L20-28), `start()` (L30-34), `stop()` (L36-39). All 7 WAV settings present. Not a stub. |
| `Sources/MakeAnIssue/MenuView.swift` | Recording-state indicator, KeyboardShortcuts.Recorder | VERIFIED | `LabeledContent("Recording", value: captureStateLabel)` at L27. `KeyboardShortcuts.Recorder("Push-to-Talk:", name: .pushToTalk)` at L29. `captureStateLabel` computed property at L45-51. `.onDisappear` fix at L33-42. |
| `Resources/Info.plist` | NSMicrophoneUsageDescription key | VERIFIED | L25-26: key present with value `Make an Issue records your voice to create GitHub issues.` `plutil -lint` exits OK. |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | CaptureState transition tests including D-04 repeat-ignore case and re-recording after finished | VERIFIED | 9 new capture-state test methods (L71-144). D-04: `testSecondStartRecordingWhileRecordingIsIgnored`. Re-recording: `testStartRecordingAfterFinishedStartsNewRecording`, `testStartRecordingAfterFinishedInvokesStartSeamAgain`. Seam invocation: `testStartRecordingInvokesStartSeam`, `testStopRecordingInvokesStopSeam`. |
| `Tests/MakeAnIssueTests/AudioRecorderTests.swift` | Unit assertions for WAV URL path, .wav extension, and WAV settings keys | VERIFIED | 7 test methods: URL extension, lastPathComponent, Application Support path, sample rate (16 kHz), mono channel, LinearPCM format, 16-bit depth. `swift test --filter AudioRecorderTests` exits 0. |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AppState.swift` | `KeyboardShortcuts` package | `onKeyDown(for: .pushToTalk)` / `onKeyUp(for: .pushToTalk)` in `init` | WIRED | L65-76: both registrations present, wrapped in `MainActor.assumeIsolated`. Registered in `init`, not in a View. |
| `AppState.swift` | `AudioRecorder.swift` | `AudioRecorder()` supplied into start/stop seam | WIRED | L35: `let recorder = AudioRecorder()` in convenience init. `onStartRecording: recorder.start`, `onStopRecording: recorder.stop` passed to designated init. Seam closures called at L99 and L104. |
| `AudioRecorder.swift` | `Application Support/MakeAnIssue/latest.wav` | `AVAudioRecorder(url: latestWavURL, settings: wavSettings)` | WIRED | L32: `AVAudioRecorder(url: url, settings: Self.wavSettings)` where `url = latestWavURL`. URL resolves `applicationSupportDirectory` + `"MakeAnIssue"` + `"latest.wav"`. |
| `MenuView.swift` | `AppState.swift` | `appState.captureState` read to show recording indicator | WIRED | L46: `switch appState.captureState` in `captureStateLabel`. L27: `LabeledContent("Recording", value: captureStateLabel)` renders the label. |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `MenuView.swift` | `captureStateLabel` / `appState.captureState` | `AppState.@Published captureState` mutated by `startRecording()`/`stopRecording()` | Yes — state transitions driven by real KeyboardShortcuts events via AVAudioRecorder | FLOWING |
| `AudioRecorder.swift` | `latestWavURL` / `recorder` | `AVAudioRecorder(url:settings:).record()` — real AVFoundation mic capture | Yes — writes actual PCM samples when mic permission granted; hardware-verified | FLOWING |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| D-04 repeat-ignore: second startRecording while recording stays .recording | `swift test --filter AppStateTests.testSecondStartRecordingWhileRecordingIsIgnored` | exit 0, 1 test, 0 failures | PASS |
| Re-recording from .finished starts new recording | `swift test --filter AppStateTests.testStartRecordingAfterFinishedStartsNewRecording` | exit 0, 1 test, 0 failures | PASS |
| WAV settings: 16 kHz sample rate | `swift test --filter AudioRecorderTests.testWavSettingsHaveCorrectSampleRate` | exit 0, 1 test, 0 failures | PASS |
| Full suite green | `swift test` | exit 0, 30 tests, 0 failures | PASS |
| Build green | `swift build` | exit 0, Build complete! | PASS |
| Info.plist valid + NSMicrophoneUsageDescription present | `plutil -lint Resources/Info.plist` + `PlistBuddy Print :NSMicrophoneUsageDescription` | OK / "Make an Issue records your voice to create GitHub issues." | PASS |
| Background hotkey fires while another app is focused | Hardware human-verify checkpoint (Task 4) | APPROVED — fresh latest.wav written while Terminal focused | PASS (human-verified) |
| Hold/release records on every press (not just first) | Hardware human-verify checkpoint (Task 4) | APPROVED — second consecutive recording works | PASS (human-verified) |
| WAV is 16000 Hz, 1 channel, 16-bit RIFF WAVE | Hardware human-verify checkpoint (Task 4) | APPROVED — `file`/`afinfo` confirmed | PASS (human-verified) |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CAPTURE-01 | 02-01 | A user-configurable global shortcut is registered and triggers while the app is in the background | SATISFIED | `KeyboardShortcuts.onKeyDown/onKeyUp(for: .pushToTalk)` registered in `AppState.init`; `KeyboardShortcuts.Recorder` in MenuView for reconfiguration; hardware-verified firing in background. REQUIREMENTS.md marks Complete. |
| CAPTURE-02 | 02-01, 02-02 | Holding the shortcut records microphone audio (push-to-talk); releasing it stops the recording | SATISFIED | State machine (`startRecording`/`stopRecording`) driven by onKeyDown/onKeyUp; `AudioRecorder.start()`/`stop()` wired through seam; menu indicator shows Idle/Recording…/Done; hardware-verified. REQUIREMENTS.md marks Complete. |
| CAPTURE-03 | 02-02 | The recording is saved as a 16 kHz mono WAV suitable as input to the ASR CLI | SATISFIED | `AudioRecorder.wavSettings`: `AVSampleRateKey: 16_000.0`, `AVNumberOfChannelsKey: 1`, `AVFormatIDKey: kAudioFormatLinearPCM`, `.wav` extension selects container; hardware-verified `file`/`afinfo` confirm format. Note: REQUIREMENTS.md shows checkbox unchecked — this appears to be a documentation lag; the implementation and human verification are complete. |

**Note on CAPTURE-03 checkbox in REQUIREMENTS.md:** The requirement checkbox is listed as `- [ ]` (unchecked) in REQUIREMENTS.md while CAPTURE-01 and CAPTURE-02 are `- [x]` (checked). The Traceability table shows CAPTURE-03 as "Pending." The implementation is fully present and hardware-verified; this is a documentation-only discrepancy that does not reflect implementation status. The REQUIREMENTS.md should be updated to mark CAPTURE-03 complete, but this does not block the phase.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | No anti-patterns found. No TODO/FIXME/TBD/XXX/HACK/PLACEHOLDER markers in any phase-modified file. |

---

### Human Verification Required

No items require further human verification. The three hardware success criteria (background hotkey, hold/release recording, 16 kHz mono WAV) were human-verified at Task 4 and APPROVED prior to this verification. This agent treats them as PASS per the provided context.

---

### Gaps Summary

No gaps. All 9 observable truths are VERIFIED, all 7 required artifacts are substantive and wired, all 4 key links are confirmed, all 3 requirement IDs (CAPTURE-01, CAPTURE-02, CAPTURE-03) are satisfied, the full test suite runs 30/30, and the build is green.

The only observation is a documentation-only discrepancy: CAPTURE-03 remains marked `- [ ]` in REQUIREMENTS.md despite the implementation being complete and hardware-verified. This is informational only and not a gap.

---

_Verified: 2026-06-24T11:40:00Z_
_Verifier: Claude (gsd-verifier)_
