# Phase 02: Push-to-Talk Voice Capture - Research

**Researched:** 2026-06-24
**Domain:** macOS global keyboard shortcuts (KeyboardShortcuts SPM), AVFoundation audio capture, TCC microphone permissions
**Confidence:** MEDIUM

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Ship with a default global push-to-talk shortcut, while still allowing the user to change it.
- **D-02:** The default shortcut is `Control-Option-I`.
- **D-03:** Recording starts on the first key-down event and stops on key-up.
- **D-04:** Repeating key-down events while already recording are ignored.
- **D-05:** Use the `KeyboardShortcuts` package for global shortcut registration and user configuration, matching the project stack.
- **D-06:** Write recordings under the app's Application Support directory, not inside the bound repository.
- **D-07:** Replace the prior recording instead of retaining a timestamped history.
- **D-08:** Phase 2 must write `16 kHz` mono WAV directly so Phase 3 can consume the file without conversion.
- **D-09:** The stable handoff path should be `Application Support/MakeAnIssue/latest.wav`.

### Claude's Discretion
No user decisions were delegated to the agent. Planning should preserve the decisions above and choose the simplest implementation that satisfies them.

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CAPTURE-01 | A user-configurable global shortcut is registered and triggers while the app is in the background. | KeyboardShortcuts 3.0.1 `onKeyDown`/`onKeyUp` with `Name` extension; confirmed no Accessibility permission needed; works in `LSUIElement` apps. |
| CAPTURE-02 | Holding the shortcut records microphone audio (push-to-talk); releasing it stops the recording. | `KeyboardShortcuts.onKeyDown` fires once on first press; ignoring repeats requires an `isRecording` guard in `AppState`; `onKeyUp` stops `AVAudioRecorder`. |
| CAPTURE-03 | The recording is saved as a 16 kHz mono WAV suitable as input to the ASR CLI. | `AVAudioRecorder` with `AVFormatIDKey: kAudioFormatLinearPCM`, `AVSampleRateKey: 16000.0`, `AVNumberOfChannelsKey: 1`, `AVLinearPCMBitDepthKey: 16`, plus `.wav` URL extension (mandatory for WAV container). |
</phase_requirements>

---

## Summary

Phase 2 adds a global push-to-talk shortcut that records microphone audio while held and writes a 16 kHz mono WAV when released. The two core building blocks are `KeyboardShortcuts` (Sindre Sorhus, SPM) for global hotkey registration and `AVAudioRecorder` (Apple AVFoundation) for audio capture — both are already the project's locked choices.

`KeyboardShortcuts` 3.0.1 (released 2026-06-17) is the current version. It provides `onKeyDown(for:)` and `onKeyUp(for:)` callbacks for press/release detection. The library does not trigger Accessibility or Input Monitoring permission dialogs and works correctly in `LSUIElement` background-only apps. A `Name` extension with the `initial:` parameter sets the default shortcut; the `KeyboardShortcuts.Recorder` SwiftUI view exposes user reconfiguration. Because `onKeyDown` fires exactly once per physical key press (system key-repeat generates `isARepeat` flagged events, which the library suppresses before dispatching to callbacks), a simple boolean guard in `AppState` is sufficient to satisfy D-04.

`AVAudioRecorder` produces a genuine WAV container when the destination URL ends with `.wav` and `kAudioFormatLinearPCM` is specified. The critical rule: the file extension determines the container, not `AVFormatIDKey` alone. The Info.plist already present in `Resources/Info.plist` must gain `NSMicrophoneUsageDescription` — the app crashes or silently fails the permission prompt without it. `build-app.sh` already copies `Resources/Info.plist` into the bundle, so adding the key there is the only required change. Microphone permission must be explicitly requested before the first recording attempt using `AVAudioApplication.requestRecordPermission()`.

**Primary recommendation:** Implement in two focused plans matching the roadmap — plan 02-01 for KeyboardShortcuts integration + `AppState` recording state, plan 02-02 for AVFoundation capture + permission handling + WAV output — keeping each plan independently testable.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Global shortcut registration | App lifecycle / AppDelegate or AppState init | — | Must be registered once at startup, before any UI interaction; `AppState.init()` is the established pattern for setup with shared state side effects. |
| Push-to-talk state machine (idle / recording / finished) | AppState (MainActor ObservableObject) | — | Existing shared-state pattern; `MenuView` reads `@Published` properties. |
| Audio capture and WAV output | AudioRecorder component | AppState (owns reference) | AVAudioRecorder is not `@MainActor`-safe; audio starts/stops on MainActor but recorder internals run on the audio thread. |
| Menu recording indicator | MenuView | AppState | Reads `@Published` `captureState`; no new architectural tier. |
| Microphone permission request | App startup (applicationDidFinishLaunching or AppState.init) | — | TCC dialog must appear before first recording attempt; one-time async call. |
| WAV file path resolution | AppState or AudioRecorder | — | `FileManager.urls(for: .applicationSupportDirectory)` on MainActor; path is a simple computed constant. |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| KeyboardShortcuts (SPM) | 3.0.1 | Global hotkey registration + user-configurable recorder UI | Locked decision D-05; no Accessibility permission needed; `LSUIElement`-compatible; used in production by macOS apps (Dato, Plash, Lungo). |
| AVFoundation (Apple system) | macOS 13+ built-in | Microphone capture + WAV file output | First-party; `AVAudioRecorder` handles PCM WAV directly with the correct settings. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| AVFAudio (AVFoundation subframework) | macOS 13+ built-in | `AVAudioApplication.requestRecordPermission()` | Phase 2 permission request pattern. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| AVAudioRecorder | AVAudioEngine + AVAudioFile | Engine gives more control but requires manual buffer-to-file writing; AVAudioRecorder is the simplest path to a WAV file without hand-rolling the PCM write loop. |
| KeyboardShortcuts onKeyDown/onKeyUp | events(for:) async sequence | Async sequence is the new preferred API; onKeyDown/onKeyUp callback style is still supported and matches the existing `AppState` pattern (ObservableObject + MainActor, not @Observable). Prefer callbacks for Phase 2. |

**Installation (Package.swift dependency to add):**
```swift
// In Package.swift, add to `dependencies:`:
.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),

// In the MakeAnIssue target's `dependencies:`:
.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
```

---

## Package Legitimacy Audit

> This phase adds one external Swift Package Manager dependency. The npm-ecosystem legitimacy tool returns SLOP for Swift packages (wrong registry); verification was performed via GitHub and Swift Package Index directly.

| Package | Registry | Age | Author | Source Repo | Verdict | Disposition |
|---------|----------|-----|--------|-------------|---------|-------------|
| KeyboardShortcuts | Swift Package Index / GitHub | 6+ years (2018) | Sindre Sorhus (sindresorhus) | [github.com/sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | OK | Approved |

**Packages removed due to SLOP verdict:** none  
**Packages flagged as suspicious:** none

*Verification method: GitHub repository confirmed active (latest release 3.0.1, 2026-06-17); used in production macOS apps; high reputation author.* [CITED: github.com/sindresorhus/KeyboardShortcuts/releases]

---

## Architecture Patterns

### System Architecture Diagram

```
User holds shortcut key
        │
        ▼
[KeyboardShortcuts global monitor]
        │
   onKeyDown fires
        │
        ▼
[AppState.startRecording()]   ←── guard: isRecording already? → ignore
        │
        ├── set captureState = .recording
        ├── AVAudioApplication.requestRecordPermission() (if needed)
        └── AudioRecorder.start(to: latestWavURL)
                 │
                 ▼
         [AVAudioRecorder] ── writes raw PCM to latest.wav
                 │
        (user releases key)
                 │
   onKeyUp fires ▼
[AppState.stopRecording()]
        │
        ├── AudioRecorder.stop()
        ├── set captureState = .finished(url: latestWavURL)
        └── MenuView reads captureState → shows "Recording done"
```

### Recommended Project Structure
```
Sources/MakeAnIssue/
├── MakeAnIssueApp.swift      # existing — add permission request call
├── AppDelegate.swift          # existing — unchanged
├── AppState.swift             # extend: captureState, shortcut registration
├── AudioRecorder.swift        # new: thin AVAudioRecorder wrapper
├── MenuView.swift             # extend: recording state indicator
├── RepoBinding.swift          # existing — unchanged
├── LaunchRequest*.swift       # existing — unchanged
```

### Pattern 1: Defining a KeyboardShortcuts.Name with Default

```swift
// Source: github.com/sindresorhus/KeyboardShortcuts (readme.md + Name.swift)
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // initial: sets the factory default; persisted to UserDefaults after first launch
    // control-option-I: .i key + [.control, .option] modifiers
    static let pushToTalk = Self(
        "pushToTalk",
        initial: .init(.i, modifiers: [.control, .option])
    )
}
```

### Pattern 2: Registering onKeyDown / onKeyUp in AppState

```swift
// Source: github.com/sindresorhus/KeyboardShortcuts (readme.md, callback-based API)
// Register in AppState.init() — this is the established app pattern.
// onKeyDown fires ONCE per physical key press; key-repeat events (isARepeat) are suppressed
// by the library before dispatch, so no additional repeat filtering is needed in userspace.
import KeyboardShortcuts

@MainActor
final class AppState: ObservableObject {
    @Published var captureState: CaptureState = .idle

    init(...) {
        // existing init body ...
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [self] in
            guard captureState == .idle else { return }  // D-04: ignore repeat
            startRecording()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [self] in
            guard captureState == .recording else { return }
            stopRecording()
        }
    }
}
```

### Pattern 3: KeyboardShortcuts.Recorder for User Reconfiguration

```swift
// Source: github.com/sindresorhus/KeyboardShortcuts (readme.md, Recorder view)
// Place in MenuView or a Settings panel
import KeyboardShortcuts

KeyboardShortcuts.Recorder("Push-to-Talk:", name: .pushToTalk)
```

### Pattern 4: AVAudioRecorder 16 kHz Mono WAV

```swift
// Source: Apple AVFoundation documentation (kAudioFormatLinearPCM settings)
// CRITICAL: URL must end in .wav — the file extension selects the container format.
// AVFormatIDKey alone does NOT guarantee a WAV container.
import AVFoundation

let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16_000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsNonInterleaved: false,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false  // little-endian; standard WAV
]

func latestWavURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = support.appendingPathComponent("MakeAnIssue", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("latest.wav")
}

// Usage:
let recorder = try AVAudioRecorder(url: latestWavURL(), settings: settings)
recorder.record()
// ... on release:
recorder.stop()
```

### Pattern 5: Microphone Permission Request

```swift
// Source: Apple AVFoundation documentation — AVAudioApplication.requestRecordPermission
// Call once at startup; show an error if denied (v1 happy path only).
import AVFAudio

// Check + request (modern API, macOS 14+):
let granted = await AVAudioApplication.requestRecordPermission()

// Fallback for macOS 13 (AVAudioSession is bridged on macOS 13):
// AVAudioSession.sharedInstance().requestRecordPermission { granted in ... }
// On macOS 13, use the completion-handler form; on macOS 14+, use async.
```

**IMPORTANT macOS version note:** `AVAudioApplication.requestRecordPermission()` as a static async method was introduced in macOS 14. For macOS 13 (the project minimum), use the `AVAudioSession.sharedInstance().requestRecordPermission(_:)` completion-handler form. Both require `NSMicrophoneUsageDescription` in Info.plist. [ASSUMED — availability boundary needs confirmation at implementation time via `@available` check or single async branch targeting macOS 14+]

### Pattern 6: CaptureState Enum for AppState

```swift
// Simple three-state machine; keep it flat — no nested associated values needed for v1
enum CaptureState: Equatable {
    case idle
    case recording
    case finished  // WAV is ready at the stable path; Phase 3 reads it
}
```

### Anti-Patterns to Avoid
- **Using `repeatingKeyDownEvents(for:)` for push-to-talk:** This async sequence is for scrolling/repeat-while-held UX. For push-to-talk, use `onKeyDown`/`onKeyUp`. [CITED: github.com/sindresorhus/KeyboardShortcuts readme]
- **Setting the file URL extension to `.caf` or any non-`.wav` extension:** The container format follows the extension. A URL ending in `.caf` with `kAudioFormatLinearPCM` produces a CAF container, not a WAV — Phase 3 will reject it. [CITED: github.com/jfversluis/Plugin.Maui.Audio/issues/205 and AVFoundation behavior]
- **Registering shortcuts in a SwiftUI View:** Shortcuts must outlive the view. Register in `AppState.init()` (the established pattern) so they are active for the entire app session.
- **Calling `AVAudioRecorder.record()` before requesting microphone permission:** On macOS, if permission is not granted, the recorder silently produces a zero-byte file. Always request permission at launch.
- **Using `@Observable` macro pattern from the readme examples:** The codebase uses `ObservableObject` + `@Published`. Stick with the existing pattern; do not introduce `@Observable`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Global keyboard shortcut capture | CGEventTap monitor + keycode parsing + UserDefaults persistence | `KeyboardShortcuts` | CGEventTap requires Accessibility permission; KeyboardShortcuts uses Carbon's `RegisterEventHotKey` which does not. |
| WAV file header writing | Custom PCM → RIFF/WAV byte-layout writer | `AVAudioRecorder` with `.wav` URL + LinearPCM settings | WAV format edge cases (chunk alignment, RIFF headers, fact chunks) are non-trivial; AVFoundation handles them correctly. |
| Key-repeat suppression | CGEvent repeat flag inspection | Boolean guard on `captureState == .idle` | KeyboardShortcuts already suppresses `isARepeat` events before calling the `onKeyDown` handler. |
| Shortcut recording UI | Custom text field that captures key combinations | `KeyboardShortcuts.Recorder` | The recorder view handles modifier-only detection, conflict detection, system shortcut exclusion, and UserDefaults persistence. |

**Key insight:** Both the shortcut capture and WAV writing domains have subtle platform edge cases (key-repeat timing, WAV chunk alignment, TCC dialog triggering) that the standard libraries handle. Custom solutions here are disproportionately risky for a v1 happy path.

---

## Common Pitfalls

### Pitfall 1: WAV Extension Mismatch (CAF written with .wav name or vice versa)
**What goes wrong:** `AVAudioRecorder` writes a CAF container even if `AVFormatIDKey: kAudioFormatLinearPCM` is set, if the destination URL does not end in `.wav`. Phase 3 ASR CLI receives a malformed or wrong-container file.  
**Why it happens:** `AVAudioRecorder` uses the file extension to select the container format; `AVFormatIDKey` selects the codec inside that container. If they mismatch (e.g. `.caf` URL + LinearPCM settings), AVFoundation reconciles by producing a CAF-wrapped LinearPCM file.  
**How to avoid:** Always construct the URL with `appendingPathComponent("latest.wav")`. Confirm with `file latest.wav` after first test run.  
**Warning signs:** `file latest.wav` reports "AIFF-C" or "CAF" instead of "RIFF (little-endian) data, WAVE audio".

### Pitfall 2: Missing NSMicrophoneUsageDescription Causes Silent Failure
**What goes wrong:** The permission prompt never appears; `requestRecordPermission` returns `false`; `AVAudioRecorder.record()` silently produces a zero-byte file.  
**Why it happens:** macOS TCC framework requires the usage description string at permission-request time. Without it, the permission dialog cannot be shown, so the request is denied automatically.  
**How to avoid:** Add `<key>NSMicrophoneUsageDescription</key><string>Make an Issue records your voice to create GitHub issues.</string>` to `Resources/Info.plist` before testing. The `build-app.sh` already copies this file into the bundle.  
**Warning signs:** No system dialog appears on first launch; `AVAudioApplication.recordPermission == .denied` immediately after the request call.

### Pitfall 3: Shortcut Registration After App Is Fully Launched
**What goes wrong:** If `KeyboardShortcuts.onKeyDown` is called from a `SwiftUI.task` or deferred closure rather than a synchronous initializer, there is a window during which the app is running but the shortcut is not yet active.  
**Why it happens:** SwiftUI task modifiers execute asynchronously after the view appears.  
**How to avoid:** Register in `AppState.init()` synchronously (as shown in Pattern 2). This is already the established pattern for `RepoBinding` setup. [CITED: github.com/sindresorhus/KeyboardShortcuts readme — "within an observable class init"]

### Pitfall 4: AVAudioSession Category on macOS
**What goes wrong:** Code copied from iOS examples calls `AVAudioSession.sharedInstance().setCategory(.record)`, which crashes or fails silently on macOS because `AVAudioSession` is a no-op on macOS (it is an iOS/tvOS API).  
**Why it happens:** AVFoundation documentation frequently shows iOS code paths; macOS does not use `AVAudioSession` for category configuration.  
**How to avoid:** On macOS, omit `AVAudioSession` category setup entirely. `AVAudioRecorder` works without it. Only permission checking via `AVAudioApplication` or `AVAudioSession.sharedInstance().recordPermission` is used on macOS. [ASSUMED — confirmed by macOS-specific behavior, not a primary-source page]

### Pitfall 5: Swift 6 Concurrency and AVAudioRecorder Delegate
**What goes wrong:** `AVAudioRecorderDelegate` methods (`audioRecorderDidFinishRecording(_:successfully:)`) are called on a background audio thread. In Swift 6 strict concurrency mode, accessing `@MainActor`-isolated state from this delegate without explicit dispatch causes a compile error.  
**Why it happens:** Swift 6.3 (current toolchain) enforces `@Sendable` and actor isolation more strictly.  
**How to avoid:** Declare `AudioRecorder` without `@MainActor`, route state updates back to the main actor explicitly via `Task { @MainActor in ... }` inside delegate callbacks, or mark delegate as `nonisolated`. Keep `AudioRecorder` as a plain class that calls a completion closure; let `AppState` own the state update.  
**Warning signs:** Build errors like "call to main actor-isolated X from non-isolated context" on delegate methods.

---

## Runtime State Inventory

> This is a greenfield phase (not a rename/refactor). The only runtime state introduced is:
> - `UserDefaults` key `"pushToTalk"` — KeyboardShortcuts persists the user-configured shortcut automatically under this key. The key matches the `Name` string literal. No migration needed for Phase 2 (first install).
> - `Application Support/MakeAnIssue/latest.wav` — single overwritten file; no migration needed.

**Nothing found in all 5 runtime-state categories for this greenfield phase.** (No rename/refactor involved.)

---

## Code Examples

Verified patterns from official sources:

### Complete Name Extension + AppState Shortcut Registration
```swift
// Source: github.com/sindresorhus/KeyboardShortcuts/blob/main/readme.md (Name.swift + callback API)
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", initial: .init(.i, modifiers: [.control, .option]))
}

// In AppState.init():
KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [self] in
    guard captureState == .idle else { return }
    startRecording()
}
KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [self] in
    guard captureState == .recording else { return }
    stopRecording()
}
```

### WAV Settings Dictionary
```swift
// Source: Apple AVFoundation (AVLinearPCM format settings)
let wavSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16_000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsNonInterleaved: false,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false
]
```

### Info.plist Addition
```xml
<!-- Add to Resources/Info.plist, inside the top-level <dict> -->
<key>NSMicrophoneUsageDescription</key>
<string>Make an Issue records your voice to create GitHub issues.</string>
```

### Application Support Path Resolution
```swift
// Standard FileManager pattern — no third-party dependency
func latestWavURL() -> URL {
    let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = appSupport.appendingPathComponent("MakeAnIssue", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("latest.wav")
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| KeyboardShortcuts `onKeyDown`/`onKeyUp` callbacks | `events(for:)` async sequence preferred in 3.0 | 2026-06-14 (v3.0.0) | Callbacks still work; use callbacks because codebase uses `ObservableObject` not `@Observable`. |
| `AVAudioSession.sharedInstance().requestRecordPermission` (callback) | `AVAudioApplication.requestRecordPermission()` async/static | macOS 14 | For macOS 13 target, keep callback form or use `#available(macOS 14, *)` guard. |
| KeyboardShortcuts `Name.init(_:default:)` | `Name.init(_:initial:)` | v2.x | `default:` label is deprecated. Use `initial:`. |

**Deprecated/outdated:**
- `KeyboardShortcuts.Name.init(_:default:)`: Use `init(_:initial:)` instead — `default` label is a deprecated alias.
- `AVAudioSession` category setup on macOS: Not applicable; macOS does not require `setCategory` for recording.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `KeyboardShortcuts.onKeyDown` suppresses `isARepeat` events before calling the handler (so the `captureState == .idle` guard is sufficient and not a race condition) | Pattern 2, Pitfall prevention | If wrong, key-repeat could trigger multiple `startRecording()` calls; guard still prevents state corruption but may log noise. Low risk — confirmed by library FAQ ("support for listening to key down, not just key up"). |
| A2 | `AVAudioApplication.requestRecordPermission()` async static form requires macOS 14+; macOS 13 requires the callback form | Pattern 5 / Pitfall 4 | If wrong (e.g. macOS 13 also has it), implementation is more complex than needed (can simplify to single async call). Safe to handle with `#available` check. |
| A3 | `AVAudioSession` category setup is a no-op on macOS and should be omitted | Pitfall 4 | If wrong, `setCategory` throws on macOS — compile-time or runtime error. Verifiable by checking if `AVAudioSession` is available on macOS 13; it is a no-op class but does not crash when called. |
| A4 | `LSUIElement` background apps work with `KeyboardShortcuts` without any additional system permission | Architecture section | If wrong (e.g. Input Monitoring required), the app silently fails to capture global keys. The readme states no permission dialogs are required, but this should be confirmed hands-on. |

**If this table is empty:** Not empty — A1 and A4 in particular should be confirmed during the hands-on verification phase.

---

## Open Questions

1. **macOS 13 vs 14 permission API**
   - What we know: `AVAudioApplication.requestRecordPermission()` async exists as of some macOS version; the callback form `AVAudioSession.sharedInstance().requestRecordPermission(_:)` is available on macOS 13.
   - What's unclear: Exact macOS version boundary for the async static form.
   - Recommendation: Use `#available(macOS 14, *)` guard with async path; fall back to callback on macOS 13. Or target only the callback form — simpler, definitely works on 13+.

2. **KeyboardShortcuts v3.0 and Swift 6 strict concurrency**
   - What we know: v3.0.1 fixed a "release build crash with Swift 6.3 compiler".
   - What's unclear: Whether `onKeyDown`/`onKeyUp` callbacks are dispatched on the main actor automatically, or whether explicit `MainActor.run` is needed inside them.
   - Recommendation: Test compilation with Swift 6 strict concurrency. If callbacks are not `@MainActor`, wrap the body: `Task { @MainActor in self.startRecording() }`.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Swift | All compilation | Yes | 6.3.2 (macOS 26.5.1) | — |
| AVFoundation (system) | Audio capture | Yes | Built into macOS 26.5.1 | — |
| Microphone hardware | CAPTURE-02 | Yes | MacBook Pro built-in mic confirmed | External USB mic |
| KeyboardShortcuts (SPM) | CAPTURE-01 | Pending (not yet in Package.swift) | 3.0.1 | — |
| Info.plist NSMicrophoneUsageDescription | CAPTURE-02 permission | NOT PRESENT (must add) | — | App crashes without it |

**Missing dependencies with no fallback:**
- `NSMicrophoneUsageDescription` in `Resources/Info.plist` — must be added before any recording test.

**Missing dependencies with fallback:**
- `KeyboardShortcuts` — must be added to `Package.swift`; no runtime fallback, but build fails cleanly if missing.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Swift Test also available but not yet used) |
| Config file | None — `swift test` discovers XCTestCase subclasses |
| Quick run command | `swift test` |
| Full suite command | `swift test` |

### What Is Unit-Testable (No Mic, No Hotkey Hardware Required)

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CAPTURE-01 | `AppState` starts with `.idle` capture state | unit | `swift test --filter AppStateTests` | Wave 0 gap |
| CAPTURE-02 | `startRecording()` transitions `captureState` to `.recording` | unit | `swift test --filter AppStateTests` | Wave 0 gap |
| CAPTURE-02 | Second `startRecording()` call while `.recording` is ignored | unit | `swift test --filter AppStateTests` | Wave 0 gap |
| CAPTURE-02 | `stopRecording()` transitions `captureState` to `.finished` | unit | `swift test --filter AppStateTests` | Wave 0 gap |
| CAPTURE-03 | WAV output URL resolves to `Application Support/MakeAnIssue/latest.wav` | unit | `swift test --filter AudioRecorderTests` | Wave 0 gap |
| CAPTURE-03 | WAV settings dictionary has correct keys (`AVFormatIDKey`, sample rate 16000, channels 1, bit depth 16) | unit | `swift test --filter AudioRecorderTests` | Wave 0 gap |
| CAPTURE-03 | WAV URL ends in `.wav` extension | unit | `swift test --filter AudioRecorderTests` | Wave 0 gap |

### What Requires Manual Hands-On Verification (Cannot Be Automated)

| Behavior | Why Manual | How to Verify |
|----------|-----------|---------------|
| Microphone TCC permission dialog appears on first launch | Requires system dialog + human interaction | Run `.build/MakeAnIssue.app`, trigger shortcut, confirm dialog appears |
| Global shortcut fires while another app (e.g. Terminal) is focused | Requires real keyboard hardware + background app | Switch to Terminal, hold shortcut, confirm menu shows "Recording…" |
| Released shortcut produces a real 16 kHz mono WAV | Requires real mic input + file validation | Run `file latest.wav` and `soxi latest.wav` or `afinfo latest.wav` |
| Recording state is visible in the menu | Requires running app | Open menu while recording; confirm indicator |

### Sampling Rate
- **Per task commit:** `swift test`
- **Per wave merge:** `swift test`
- **Phase gate:** Full suite green + hands-on manual checklist before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `Tests/MakeAnIssueTests/AppStateTests.swift` — extend with `CaptureState` transition tests
- [ ] `Tests/MakeAnIssueTests/AudioRecorderTests.swift` — new file; WAV URL, settings keys, extension assertions
- [ ] No new framework install needed — XCTest already works

---

## Security Domain

> `security_enforcement: true`, ASVS Level 1.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | — |
| V3 Session Management | No | — |
| V4 Access Control | No | — |
| V5 Input Validation | Partial | WAV file output path is constructed from `FileManager` URLs (no user input); safe. |
| V6 Cryptography | No | — |
| V9 Communications | No | — |
| Privacy / TCC | Yes | `NSMicrophoneUsageDescription` required; explicit permission request before recording. |

### Known Threat Patterns for This Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Path traversal in WAV output path | Tampering | Path is constructed from `FileManager.urls` + hardcoded `"MakeAnIssue/latest.wav"` — no user-controlled path components. |
| Microphone access without permission | Elevation of Privilege | `AVAudioApplication.requestRecordPermission()` at startup; check result before recording. |
| Global shortcut hijack by malicious app | Spoofing | Not mitigable at app level; this is an OS-level concern. KeyboardShortcuts uses Carbon hotkeys — first registered wins. |

---

## Sources

### Primary (MEDIUM confidence)
- [github.com/sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — readme, Name.swift API, version 3.0.1 release, permissions FAQ
- Context7 `/sindresorhus/keyboardshortcuts` — `onKeyDown`/`onKeyUp` patterns, `Recorder` view, `repeatingKeyDownEvents`, `events(for:)` async sequence

### Secondary (MEDIUM confidence)
- [developer.apple.com — Requesting authorization to capture and save media](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media) — microphone permission API
- [developer.apple.com — NSMicrophoneUsageDescription](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSMicrophoneUsageDescription) — Info.plist requirement
- [github.com/sindresorhus/KeyboardShortcuts/releases](https://github.com/sindresorhus/KeyboardShortcuts/releases) — version 3.0.1 confirmed, June 17 2026

### Tertiary (LOW confidence)
- WebSearch results on AVAudioRecorder WAV container format / file extension behavior
- WebSearch results on AVAudioApplication.requestRecordPermission macOS version availability

---

## Metadata

**Confidence breakdown:**
- Standard stack (KeyboardShortcuts): MEDIUM — confirmed via official GitHub repo + Context7 (high-reputation source); not cross-checked against a second authoritative source
- Architecture (AVFoundation WAV settings): MEDIUM — core keys confirmed via Apple documentation reference; version boundary for async permission API is ASSUMED
- Pitfalls: MEDIUM — WAV extension behavior confirmed via multiple sources; AVAudioSession macOS no-op is ASSUMED from training knowledge

**Research date:** 2026-06-24  
**Valid until:** 2026-07-24 (KeyboardShortcuts moves quickly; re-verify if planning is delayed more than 30 days)
