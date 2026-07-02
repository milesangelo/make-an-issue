---
phase: 02-push-to-talk-voice-capture
reviewed: 2026-06-24T00:00:00Z
depth: standard
files_reviewed: 6
files_reviewed_list:
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/AudioRecorder.swift
  - Sources/MakeAnIssue/MenuView.swift
  - Resources/Info.plist
  - Tests/MakeAnIssueTests/AppStateTests.swift
  - Tests/MakeAnIssueTests/AudioRecorderTests.swift
findings:
  critical: 2
  warning: 4
  info: 2
  total: 8
status: issues_found
---

# Phase 2: Code Review Report

**Reviewed:** 2026-06-24
**Depth:** standard
**Files Reviewed:** 6
**Status:** issues_found

## Summary

This phase adds push-to-talk voice capture: a global hotkey (`AppState`), an
`AVAudioRecorder` wrapper (`AudioRecorder`), microphone permission handling, and
menu UI for capture state. The state-machine logic in `AppState` is clean and
well-tested, and the `KeyboardShortcuts` integration is thoughtfully handled
(the `.onDisappear` workaround is correct and well-documented).

The core defects are concentrated in the **boundary between the recording state
machine and the actual audio subsystem**. The seam was designed for testability
(injectable closures), but it is strictly one-directional: `AppState` can command
the recorder but can never learn whether recording actually started. Combined
with silent error-swallowing (`try?`) in `AudioRecorder.start()` and an
asynchronous permission grant that races the synchronously-registered hotkey, the
app can confidently display "Recording…" while capturing nothing — with no path
for the user or the code to detect it. These are the two BLOCKERs.

The test suite is solid for the pure state machine and the WAV/URL configuration,
but it exercises **none** of the failure paths (recorder init failure, denied
permission, encode error), which is precisely why those defects slipped through.

## Critical Issues

### CR-01: Recording failure is silently swallowed; UI/state desync to "Recording…" with no audio

**File:** `Sources/MakeAnIssue/AudioRecorder.swift:30-34`, `Sources/MakeAnIssue/AppState.swift:93-100`

**Issue:** `AudioRecorder.start()` swallows every failure mode:

```swift
func start() {
    let url = latestWavURL
    recorder = try? AVAudioRecorder(url: url, settings: Self.wavSettings)  // error -> nil, swallowed
    recorder?.record()                                                     // discards Bool return
}
```

Two distinct failures are discarded:
1. `AVAudioRecorder(url:settings:)` throwing (bad path, unwritable directory, denied mic permission, invalid settings) — `try?` turns it into `nil`.
2. `record()` returns `Bool` indicating whether recording actually began (it returns `false` when, e.g., permission is not granted) — the return value is ignored.

Meanwhile `AppState.startRecording()` has *already* committed the state transition before calling the seam:

```swift
func startRecording() {
    guard captureState != .recording else { return }
    captureState = .recording   // committed unconditionally
    onStartRecording()          // failure here cannot roll the state back
}
```

Because the seam closure returns `Void`, `AppState` has no channel to learn that
recording failed. Result: `captureState` is `.recording`, `MenuView` shows
"Recording…", the user speaks, releases the key, and the app reports "Done" — but
`latest.wav` is empty or stale. This is silent data loss of the user's primary
input, with affirmatively misleading UI.

**Fix:** Make the seam report success and only transition on confirmed start. Make
`start()` return a `Bool` (and surface the error):

```swift
// AudioRecorder.swift
func start() -> Bool {
    let url = latestWavURL
    do {
        let recorder = try AVAudioRecorder(url: url, settings: Self.wavSettings)
        self.recorder = recorder
        return recorder.record()   // false if it could not begin
    } catch {
        NSLog("AudioRecorder.start failed: \(error)")
        recorder = nil
        return false
    }
}

// AppState.swift — seam becomes () -> Bool
func startRecording() {
    guard captureState != .recording else { return }
    guard onStartRecording() else {
        statusText = "Recording failed — check microphone permission"
        captureState = .idle
        return
    }
    captureState = .recording
}
```

Add a test that injects a failing start seam and asserts the state stays `.idle`.

---

### CR-02: Microphone permission is requested asynchronously but the hotkey is live immediately — first press records nothing

**File:** `Sources/MakeAnIssue/AppState.swift:65-82`

**Issue:** In `init`, the push-to-talk key handlers are registered synchronously,
but the permission request is fired in a detached, un-awaited `Task`:

```swift
KeyboardShortcuts.onKeyDown(for: .pushToTalk) { ... startRecording() }   // live now
KeyboardShortcuts.onKeyUp(for: .pushToTalk)   { ... stopRecording() }    // live now

Task {
    await AppState.requestMicrophonePermission()   // resolves later, off the init path
}
```

On first launch (or any launch before the TCC grant resolves), the user can press
the hotkey before `requestRecordPermission()` has returned. `AVAudioRecorder.record()`
then fails because permission is not yet granted. Combined with CR-01, the failure
is invisible: the app shows "Recording…" and captures nothing. Even after CR-01 is
fixed, the very first push-to-talk attempt during the permission prompt will fail
with no useful guidance, which is a poor first-run experience for the core feature.

Additionally, the result of the permission request is discarded (`_ = await ...`
on macOS 14, no capture on macOS 13), so the app never knows whether the user
denied access and can never surface "microphone denied" guidance.

**Fix:** Capture and store the permission result, and gate recording on it. At
minimum, store an `@Published var micPermissionGranted` updated when the request
resolves, and in `startRecording()` surface a clear message when it is denied:

```swift
Task {
    let granted = await AppState.requestMicrophonePermission()
    micPermissionGranted = granted
    if !granted { statusText = "Microphone access denied — enable in System Settings" }
}

private static func requestMicrophonePermission() async -> Bool {
    if #available(macOS 14, *) {
        return await AVAudioApplication.requestRecordPermission()
    } else {
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
```

Then have `startRecording()` short-circuit with a clear status when permission is
not granted, rather than transitioning to `.recording`.

## Warnings

### WR-01: No `AVAudioRecorderDelegate` — encode errors during recording are undetectable

**File:** `Sources/MakeAnIssue/AudioRecorder.swift:7-39`

**Issue:** `AudioRecorder` subclasses `NSObject` (the comment at line 4 even
explains the rationale for not being `@MainActor` "because AVAudioRecorder
callbacks fire on a background audio thread"), but it never sets itself as the
recorder's `delegate` and implements neither `audioRecorderDidFinishRecording(_:successfully:)`
nor `audioRecorderEncodeErrorDidOccur(_:error:)`. An encode/IO error that occurs
*after* `record()` succeeds (disk full, interruption) is therefore completely
silent, and `stop()` will report a normal completion. The `NSObject` base class
and the explanatory comment imply delegate handling was intended but not wired up.

**Fix:** Conform to `AVAudioRecorderDelegate`, set `recorder.delegate = self` in
`start()`, and route `audioRecorderEncodeErrorDidOccur` back to `AppState` (e.g.,
via an `onRecordingError` closure on the same seam) so the failure can update
`statusText`/`captureState`.

---

### WR-02: Unchecked subscript and swallowed directory-creation error in `latestWavURL`

**File:** `Sources/MakeAnIssue/AudioRecorder.swift:11-17`

**Issue:**

```swift
let support = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]   // unchecked [0]
let dir = support.appendingPathComponent("MakeAnIssue", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)  // error swallowed
return dir.appendingPathComponent("latest.wav")
```

The `[0]` subscript crashes if the array is empty. In practice `.applicationSupportDirectory`
is reliably non-empty, so this is a robustness concern rather than a likely crash —
hence WARNING, not BLOCKER. More impactful: the `createDirectory` failure is
swallowed with `try?`. If the directory cannot be created, `start()` (CR-01) will
then fail to construct the recorder, and the chain of swallowed errors means the
user gets "Recording…" with no file. This compounds CR-01.

**Fix:** Use `.first` with a sensible fallback (or fail loudly), and propagate the
directory-creation error to the caller instead of discarding it:

```swift
guard let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
    // surface error rather than crash
}
```

Consider making `latestWavURL` throwing, or precomputing/validating the directory
once at init so the failure is detected before the user attempts to record.

---

### WR-03: Side effect (directory creation) inside a computed property accessed on every recording

**File:** `Sources/MakeAnIssue/AudioRecorder.swift:11-17`

**Issue:** `latestWavURL` is a `var` computed property that performs filesystem
mutation (`createDirectory`) as a side effect every time it is read. It is read in
`start()` and also by three tests (`AudioRecorderTests.swift:9,15,21`), each of
which silently creates `~/Library/Application Support/MakeAnIssue/` on the
developer/CI machine as a side effect of merely asking for the URL. Computed
property getters are expected to be pure; hiding a mkdir behind a property read is
surprising and makes the tests have filesystem side effects they don't declare.

**Fix:** Separate path computation (pure) from directory preparation. Expose a pure
`latestWavURL` and do `createDirectory` explicitly inside `start()` (or a dedicated
`prepare()` method), so reading the URL has no side effects.

---

### WR-04: Recording is never finalized/cleaned up if `stop()` is not called (orphaned recorder + permanent "Recording…")

**File:** `Sources/MakeAnIssue/AppState.swift:71-76`, `Sources/MakeAnIssue/AudioRecorder.swift:36-39`

**Issue:** `stopRecording()` only runs on `onKeyUp`. The `onKeyUp` handler guards
`captureState == .recording`. If a key-up event is missed (focus change while held,
the very `.menuOpen`/`.normal` mode transitions the code itself works around in
`MenuView`, or the system dropping the up event), the recorder keeps running
indefinitely, `captureState` stays `.recording` forever, and a second push-to-talk
is suppressed by the `guard captureState != .recording` in `startRecording()` —
the feature becomes permanently stuck with no recovery path. There is no timeout,
no max-duration cap, and no way to force-stop from the UI.

**Fix:** Add a recovery path: a max-recording-duration timeout in `AudioRecorder`/`AppState`
that auto-stops and resets to `.idle`/`.finished`, and/or a click-to-stop affordance
in `MenuView`. Given that the existing `.onDisappear` comment documents real-world
key-monitor mode flapping, a missed key-up is a realistic scenario, not a hypothetical.

## Info

### IN-01: `audioRecorder` is stored on `AppState` but never used directly

**File:** `Sources/MakeAnIssue/AppState.swift:24,61`

**Issue:** `AppState` stores `private let audioRecorder: AudioRecorder`, but every
interaction goes through the `onStartRecording`/`onStopRecording` closures. The
stored property is only used to keep the recorder alive (the closures `recorder.start`/
`recorder.stop` capture the instance, so even that is arguably redundant). It is
otherwise dead — no method reads `audioRecorder`. This is intentional retain-anchoring,
but it reads as unused and will confuse future maintainers.

**Fix:** Either drop the property (the closures already retain the recorder) or add
a brief comment stating it exists solely to anchor the recorder's lifetime. If
WR-01 (delegate wiring) or CR-01 (bidirectional seam) is implemented, this property
likely becomes the natural integration point and the ambiguity resolves itself.

---

### IN-02: Tests cover only happy paths; no failure-mode coverage

**File:** `Tests/MakeAnIssueTests/AppStateTests.swift`, `Tests/MakeAnIssueTests/AudioRecorderTests.swift`

**Issue:** The state-machine tests are thorough for valid transitions, and the
WAV/URL tests verify configuration. But there is zero coverage of failure paths:
no test injects a failing start seam, no test asserts behavior when permission is
denied, and `AudioRecorder.start()/stop()` are never exercised (only `latestWavURL`
and `wavSettings`). This is the direct reason CR-01 and CR-02 are present —
the seam was built for testability but the failure branch was never tested. Note
also that `AudioRecorderTests` reads `latestWavURL`, which (per WR-03) creates a
real directory on the test machine.

**Fix:** When implementing CR-01's bidirectional seam, add tests asserting that a
failed start keeps `captureState == .idle` and updates `statusText`. Avoid
real-filesystem side effects in unit tests.

---

_Reviewed: 2026-06-24_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
