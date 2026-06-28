# Phase 02: Push-to-Talk Voice Capture - Pattern Map

**Mapped:** 2026-06-24
**Files analyzed:** 7 new/modified files
**Analogs found:** 7 / 7

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Package.swift` | config | — | `Package.swift` (self) | exact |
| `Sources/MakeAnIssue/AppState.swift` | store/state | event-driven | `Sources/MakeAnIssue/AppState.swift` (self) | exact |
| `Sources/MakeAnIssue/AudioRecorder.swift` | service | file-I/O | `Sources/MakeAnIssue/RepoBinding.swift` | role-match (focused pure-Swift utility class) |
| `Sources/MakeAnIssue/MenuView.swift` | component | request-response | `Sources/MakeAnIssue/MenuView.swift` (self) | exact |
| `Resources/Info.plist` | config | — | `Resources/Info.plist` (self) | exact |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | test | — | `Tests/MakeAnIssueTests/AppStateTests.swift` (self) | exact |
| `Tests/MakeAnIssueTests/AudioRecorderTests.swift` | test | — | `Tests/MakeAnIssueTests/RepoBindingTests.swift` | role-match (unit tests for a pure utility type) |

---

## Pattern Assignments

### `Package.swift` (config)

**Analog:** `Package.swift` (current file)

**Current dependency block** (lines 1-24, full file — no existing dependencies array):
```swift
// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "make-an-issue",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MakeAnIssue", targets: ["MakeAnIssue"])
    ],
    targets: [
        .executableTarget(
            name: "MakeAnIssue",
            path: "Sources/MakeAnIssue"
        ),
        .testTarget(
            name: "MakeAnIssueTests",
            dependencies: ["MakeAnIssue"],
            path: "Tests/MakeAnIssueTests"
        )
    ]
)
```

**Pattern to apply — add `dependencies:` array at package level and product dependency to the target:**
```swift
// Add between `platforms:` and `products:`:
dependencies: [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
],

// Extend .executableTarget to add dependencies key:
.executableTarget(
    name: "MakeAnIssue",
    dependencies: [
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
    ],
    path: "Sources/MakeAnIssue"
),
```

---

### `Sources/MakeAnIssue/AppState.swift` (store/state, event-driven)

**Analog:** `Sources/MakeAnIssue/AppState.swift` (current file — extend, do not replace)

**Existing class shape** (lines 1-33):
```swift
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var statusText: String
    @Published var launchCWD: String?
    @Published var boundRepo: RepoBinding?
    @Published var boundRepoDisplayText: String

    init(
        statusText: String = "Ready",
        launchCWD: String? = nil,
        boundRepo: RepoBinding? = nil,
        boundRepoDisplayText: String = "No repository bound"
    ) {
        self.statusText = statusText
        self.launchCWD = launchCWD
        self.boundRepo = boundRepo
        self.boundRepoDisplayText = boundRepoDisplayText
    }

    func handleLaunchRequest(_ request: LaunchRequest) { ... }
}
```

**Pattern to apply — new imports, new @Published property, enum, init extension, and methods:**

Add to imports:
```swift
import KeyboardShortcuts
```

Add `CaptureState` enum (adjacent to class, same file):
```swift
// Keep flat — no nested associated values needed for v1
enum CaptureState: Equatable {
    case idle
    case recording
    case finished
}
```

Add `@Published` property alongside existing ones (same pattern: `@Published var …`):
```swift
@Published var captureState: CaptureState = .idle
```

Add `KeyboardShortcuts.Name` extension (top of file, outside class, after imports):
```swift
extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", initial: .init(.i, modifiers: [.control, .option]))
}
```

Extend `init()` body — append after existing init body:
```swift
KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [self] in
    guard captureState == .idle else { return }
    startRecording()
}
KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [self] in
    guard captureState == .recording else { return }
    stopRecording()
}
```

New methods (same style as `handleLaunchRequest` — no return value, mutate published state):
```swift
func startRecording() {
    captureState = .recording
    audioRecorder.start()
}

func stopRecording() {
    audioRecorder.stop()
    captureState = .finished
}
```

Private stored property (AudioRecorder — see AudioRecorder.swift section):
```swift
private let audioRecorder = AudioRecorder()
```

---

### `Sources/MakeAnIssue/AudioRecorder.swift` (service, file-I/O)

**Analog:** `Sources/MakeAnIssue/RepoBinding.swift` — a focused, pure-Swift type with no `@MainActor`, no `ObservableObject`, no UI imports. Contains only logic and Foundation.

**RepoBinding shape to copy** (lines 1-45):
```swift
import Foundation

struct RepoBinding: Equatable {
    let rootURL: URL
    // ... properties

    static func resolve(from cwd: URL, fileManager: FileManager = .default) -> RepoBinding? {
        // pure logic, no side effects in properties
    }

    private static func helperMethod(...) -> Bool { ... }
}
```

**Pattern to apply — new file, plain class, AVFoundation only:**
```swift
import AVFoundation
import Foundation

// Not @MainActor — AVAudioRecorder callbacks fire on a background audio thread.
// AppState owns this and calls start()/stop() from MainActor; state updates route
// back to AppState via a completion closure rather than direct @Published mutation.
final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?

    // Stable output path: Application Support/MakeAnIssue/latest.wav
    var latestWavURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MakeAnIssue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("latest.wav")
    }

    // WAV settings — URL extension (.wav) selects container; LinearPCM selects codec
    static let wavSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    func start() {
        let url = latestWavURL
        recorder = try? AVAudioRecorder(url: url, settings: Self.wavSettings)
        recorder?.record()
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}
```

Note on Swift 6 concurrency (Pitfall 5 from RESEARCH.md): `AudioRecorder` must NOT be `@MainActor`. If `AVAudioRecorderDelegate` callbacks are added later, route state updates via `Task { @MainActor in … }`.

---

### `Sources/MakeAnIssue/MenuView.swift` (component, request-response)

**Analog:** `Sources/MakeAnIssue/MenuView.swift` (current file — extend, do not replace)

**Existing structure** (lines 1-28):
```swift
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make an Issue").font(.headline)
            Divider()
            LabeledContent("Status", value: appState.statusText)
            if let boundRepo = appState.boundRepo {
                LabeledContent("Repository", value: boundRepo.displayName)
                Text(boundRepo.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                LabeledContent("Repository", value: appState.boundRepoDisplayText)
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}
```

**Pattern to apply — add capture state indicator using same `LabeledContent` style:**

Add inside `VStack`, after the `Divider()` and before the existing `LabeledContent("Status", …)` line — or replace `statusText` display with a combined view. Follow existing `LabeledContent` + `if/else` pattern:
```swift
// Reads appState.captureState — same @EnvironmentObject access pattern as boundRepo
LabeledContent("Recording", value: captureStateLabel)

// Computed property (outside body, inside struct):
private var captureStateLabel: String {
    switch appState.captureState {
    case .idle:      return "Idle"
    case .recording: return "Recording…"
    case .finished:  return "Done"
    }
}
```

Optionally add shortcut recorder for user reconfiguration (per D-01). Same `import KeyboardShortcuts` at top:
```swift
import KeyboardShortcuts

// Inside VStack:
KeyboardShortcuts.Recorder("Push-to-Talk:", name: .pushToTalk)
```

---

### `Resources/Info.plist` (config)

**Analog:** `Resources/Info.plist` (current file — add one key/value pair inside the existing top-level `<dict>`)

**Existing structure** (lines 1-26 — add before closing `</dict>`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist ...>
<plist version="1.0">
<dict>
    <!-- ... existing keys ... -->
    <key>LSUIElement</key>
    <true/>
    <!-- INSERT HERE: -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Make an Issue records your voice to create GitHub issues.</string>
</dict>
</plist>
```

---

### `Tests/MakeAnIssueTests/AppStateTests.swift` (test)

**Analog:** `Tests/MakeAnIssueTests/AppStateTests.swift` (current file — extend with new test methods)

**Existing test shape to match** (lines 1-76):
- Class: `@MainActor final class AppStateTests: XCTestCase`
- Setup: `temporaryDirectory` created in `setUpWithError`, removed in `tearDownWithError`
- Tests: one assert per test method, `XCTAssertEqual` / `XCTAssertNil`
- No mocks — tests operate on real `AppState()` instances directly

**Pattern to apply — new test methods in same class, same `@MainActor` isolation:**
```swift
func testInitialCaptureStateIsIdle() {
    let state = AppState()

    XCTAssertEqual(state.captureState, .idle)
}

func testStartRecordingTransitionsToRecording() {
    let state = AppState()
    // Note: startRecording() calls audioRecorder.start() — may need AudioRecorder injectable
    // for unit tests. If AudioRecorder.start() is a no-op when no mic is present, call directly.
    state.startRecording()

    XCTAssertEqual(state.captureState, .recording)
}

func testSecondStartRecordingWhileRecordingIsIgnored() {
    let state = AppState()
    state.startRecording()
    state.startRecording()  // should be ignored per D-04

    XCTAssertEqual(state.captureState, .recording)
}

func testStopRecordingTransitionsToFinished() {
    let state = AppState()
    state.startRecording()
    state.stopRecording()

    XCTAssertEqual(state.captureState, .finished)
}
```

Implementation note: If `startRecording()` directly calls `AudioRecorder.start()` (which hits the real mic), the state transition tests may fail without mic hardware or permissions. The simplest fix is to have `AppState.startRecording()` accept an optional injected recorder, OR to make `AudioRecorder.start()` silently succeed when `AVAudioRecorder` init fails (e.g., no permission). Test only the state machine transitions; hardware behavior is covered by the manual checklist.

---

### `Tests/MakeAnIssueTests/AudioRecorderTests.swift` (test, file-I/O)

**Analog:** `Tests/MakeAnIssueTests/LaunchRequestStoreTests.swift` — tests a file-I/O utility type; uses `temporaryDirectory` setup, `XCTAssertEqual`, and file existence assertions.

**LaunchRequestStoreTests shape to copy** (lines 1-62):
```swift
import XCTest
@testable import MakeAnIssue

final class LaunchRequestStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSpecificBehavior() throws {
        // Arrange
        // Act
        // Assert with XCTAssertEqual / XCTAssertFalse / XCTAssertTrue
    }
}
```

**Pattern to apply — new file, same import block and XCTestCase shape:**
```swift
import AVFoundation
import XCTest
@testable import MakeAnIssue

final class AudioRecorderTests: XCTestCase {
    func testLatestWavURLEndsWithWavExtension() {
        let recorder = AudioRecorder()

        XCTAssertEqual(recorder.latestWavURL.pathExtension, "wav")
    }

    func testLatestWavURLIsUnderApplicationSupportMakeAnIssue() {
        let recorder = AudioRecorder()
        let url = recorder.latestWavURL

        XCTAssertTrue(url.path.contains("Application Support/MakeAnIssue"))
        XCTAssertEqual(url.lastPathComponent, "latest.wav")
    }

    func testWavSettingsHaveCorrectSampleRate() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 16_000.0)
    }

    func testWavSettingsHaveMonoChannel() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
    }

    func testWavSettingsHaveLinearPCMFormat() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
    }

    func testWavSettingsHave16BitDepth() {
        let settings = AudioRecorder.wavSettings

        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
    }
}
```

---

## Shared Patterns

### @MainActor ObservableObject
**Source:** `Sources/MakeAnIssue/AppState.swift` lines 4-5
**Apply to:** Any new state-owning type
```swift
@MainActor
final class AppState: ObservableObject {
```
Do NOT use `@Observable` macro — the codebase is on `ObservableObject` + `@Published`.

### @EnvironmentObject State Access in Views
**Source:** `Sources/MakeAnIssue/MenuView.swift` line 4
**Apply to:** `MenuView` extensions; do not create new environment injections
```swift
@EnvironmentObject private var appState: AppState
```

### Test Class Isolation Pattern
**Source:** `Tests/MakeAnIssueTests/AppStateTests.swift` lines 6-16
**Apply to:** `AppStateTests` extensions and new `AudioRecorderTests`
```swift
private var temporaryDirectory: URL!

override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
}

override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporaryDirectory)
}
```

### Import Style
**Source:** All existing `.swift` files
**Apply to:** All new/modified `.swift` files
- System frameworks listed alphabetically before third-party
- No `@_exported` or re-export patterns
- `@testable import MakeAnIssue` only in test files

---

## No Analog Found

All files have analogs. No gaps requiring RESEARCH.md patterns as a substitute — RESEARCH.md patterns are incorporated as the "pattern to apply" sections above, validated against the codebase conventions.

---

## Metadata

**Analog search scope:** `Sources/MakeAnIssue/`, `Tests/MakeAnIssueTests/`, `Package.swift`, `Resources/Info.plist`
**Files scanned:** 10 Swift files + Package.swift + Info.plist
**Pattern extraction date:** 2026-06-24
