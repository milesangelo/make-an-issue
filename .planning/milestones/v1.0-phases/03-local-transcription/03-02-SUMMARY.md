---
phase: 03-local-transcription
plan: "02"
subsystem: Transcriber + AppState + MenuView
status: complete
tags:
  - swift
  - transcriber
  - app-state
  - menu-view
  - shell-quoting
  - async-await
  - testing

dependency_graph:
  requires:
    - CLIRunner.run(command:workingDirectory:timeout:) — Plan 01
    - CaptureState enum (idle/recording/finished) — Phase 02
    - AppState closure-seam pattern — Phase 02
    - AudioRecorder.latestWavURL — Phase 02
  provides:
    - Transcriber.prepare(command:wavURL:) — pure; throws TranscriberError
    - Transcriber.run(command:wavURL:) — async; calls CLIRunner, trims stdout
    - TranscriberError enum: emptyCommand, missingWavToken, asrFailed, asrTimedOut, emptyTranscript
    - CaptureState.transcribing (new case)
    - AppState.transcript: String? (@Published)
    - AppState.transcriptError: String? (@Published)
    - AppState.asrCommandKey: String (static shared UserDefaults key)
    - AppState.onRunTranscription seam: (URL) async throws -> String
    - MenuView: @AppStorage(AppState.asrCommandKey) TextField + transcript display
  affects:
    - Phase 04 (AppState.onRunTranscription seam reused; CLIRunner.workingDirectory can be set)
    - Phase 05 (no direct impact — transcript stored in AppState for gh issue create)

tech_stack:
  added: []
  patterns:
    - "POSIX single-quote escaping for {wav} path: ' → '\\'' (Pattern 3 from research)"
    - "onRunTranscription closure seam — same pattern as onStartRecording/onStopRecording (Pattern 4)"
    - "Separate @Published transcript property vs CaptureState (Pattern 5)"
    - "Task { await MainActor.run } for main-actor hop from async transcription (D-10)"
    - "@AppStorage(AppState.asrCommandKey) + UserDefaults.standard share single key (Pitfall 5 avoided)"

key_files:
  created:
    - Sources/MakeAnIssue/Transcriber.swift
    - Tests/MakeAnIssueTests/TranscriberTests.swift
  modified:
    - Sources/MakeAnIssue/AppState.swift
    - Sources/MakeAnIssue/MenuView.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift

decisions:
  - "onRunTranscription seam: (URL) async throws -> String — throws idiom matches Swift async patterns; tests inject stub closures"
  - "captureState on success: .finished (not .idle); matches startRecording() allow-list which permits .finished as a prior state"
  - "asrCommandKey = 'asrCommand' — single shared constant used in both AppState (UserDefaults.standard) and MenuView (@AppStorage)"
  - "message(for:) private static func maps all TranscriberError cases to short user-facing strings (D-11)"
  - "Existing testStopRecordingTransitionsToFinished renamed to testStopRecordingTransitionsToTranscribing (behavioral change: stopRecording() → .transcribing not .finished)"

metrics:
  duration: "295s"
  completed: "2026-06-24"
  tasks_completed: 3
  files_created: 2
  files_modified: 3
---

# Phase 03 Plan 02: Transcriber + AppState + MenuView Summary

One-liner: Transcriber validates and POSIX-single-quotes the {wav} path, runs the ASR command via CLIRunner, and returns the trimmed stdout; AppState drives .transcribing async off the main actor and resets on failure; MenuView shows the ASR command field (@AppStorage) and a selectable transcript block.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Transcriber (validate + {wav} quoting + run via CLIRunner) + TranscriberTests | ba82503 | Sources/MakeAnIssue/Transcriber.swift, Tests/MakeAnIssueTests/TranscriberTests.swift |
| 2 | Wire transcription into AppState (.transcribing state, seam, async dispatch, tests) | a5c4405 | Sources/MakeAnIssue/AppState.swift, Sources/MakeAnIssue/MenuView.swift, Tests/MakeAnIssueTests/AppStateTests.swift |
| 3 | MenuView ASR-command TextField + transcript display | 48989af | Sources/MakeAnIssue/MenuView.swift |

## Key Symbols (for downstream phases)

### onRunTranscription seam shape

```swift
// Designated init parameter (default wires real Transcriber):
onRunTranscription: @escaping (URL) async throws -> String = { url in
    let cmd = UserDefaults.standard.string(forKey: AppState.asrCommandKey) ?? ""
    return try await Transcriber.run(command: cmd, wavURL: url)
}

// Test stub (success):
onRunTranscription: { _ in "Hello world" }

// Test stub (failure):
onRunTranscription: { _ in throw TranscriberError.asrTimedOut }
```

### asrCommandKey value

```swift
static let asrCommandKey = "asrCommand"
// Used in: AppState (UserDefaults.standard) + MenuView (@AppStorage)
```

### Final CaptureState cases

```swift
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing   // NEW (D-10)
    case finished
}
```

### TranscriberError cases

```swift
enum TranscriberError: Error, Equatable {
    case emptyCommand                           // D-03
    case missingWavToken                        // D-05
    case asrFailed(exitCode: Int32, stderr: String)   // D-11
    case asrTimedOut                            // D-12
    case emptyTranscript                        // empty stdout after trim
}
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] MenuView .transcribing case added during Task 2 (not Task 3)**

- **Found during:** Task 2 — `swift build` failed with "switch must be exhaustive" after adding `.transcribing` to CaptureState
- **Issue:** MenuView's `captureStateLabel` switch needed the new case for the build to succeed (and thus for Task 2 tests to compile)
- **Fix:** Added `.transcribing: return "Transcribing…"` to MenuView's switch during Task 2; Task 3 then added the ASR command field and transcript display
- **Files modified:** Sources/MakeAnIssue/MenuView.swift
- **Commit:** a5c4405

**2. [Rule 1 - Bug] Updated 2 existing AppState tests broken by behavioral change**

- **Found during:** Task 2 — `testStopRecordingTransitionsToFinished` and `testStartRecordingAfterFinishedStartsNewRecording` expected `.finished` immediately after `stopRecording()` but new behavior sets `.transcribing` first
- **Issue:** `stopRecording()` now enters `.transcribing` and dispatches an async transcription Task; the immediate state is `.transcribing` not `.finished`
- **Fix:** Renamed `testStopRecordingTransitionsToFinished` → `testStopRecordingTransitionsToTranscribing`; updated both async tests to inject an `onRunTranscription` stub and `await Task.sleep` to let the Task settle before asserting `.finished`
- **Files modified:** Tests/MakeAnIssueTests/AppStateTests.swift
- **Commit:** a5c4405

## Threat Model Coverage

| Threat | Mitigation | Implemented |
|--------|-----------|-------------|
| T-03-05 ({wav} path injection) | POSIX single-quote escaping — `'` → `'\''` | Yes — Transcriber.prepare(); verified by testWavSubstitutionQuoting, testPathWithSingleQuoteIsEscaped |
| T-03-06 (empty/malformed command) | prepare() throws emptyCommand/missingWavToken before any spawn | Yes — verified by testEmptyCommandThrowsEmptyCommandError, testMissingWavTokenError, testEmptyCommandShowsError |
| T-03-07 (user command body) | Accept — user controls full command; only {wav} path is escaped | By design (D-02) |
| T-03-08 (transcript in UI) | stdout in SwiftUI Text view only; stderr not merged (D-08) | Yes — CLIResult.success stdout separate from stderr |
| T-03-09 (hung ASR process) | Inherited from CLIRunner 120s timeout; .asrTimedOut → .idle reset | Yes — verified by testTimeoutResetsState |

## Verification Results

- `swift build` — success
- `swift test --filter TranscriberTests` — 9 tests, 0 failures
- `swift test --filter AppStateTests` — 26 tests, 0 failures (19 baseline + 6 new transcription + 1 renamed)
- `swift test` (full suite) — 58 tests, 0 failures (43 baseline + 9 TranscriberTests + 6 new AppStateTests)

## Known Stubs

None — all data flows are wired. The ASR command is empty by default (UserDefaults cold start), which is correct: the user must type their command in the menu field. The empty command case is handled gracefully (sets status text "Set your ASR command in the menu to transcribe").

## Threat Flags

None — no new network endpoints, auth paths, or schema changes beyond those already covered in the threat model.

## Self-Check: PASSED

- [x] Sources/MakeAnIssue/Transcriber.swift exists
- [x] Tests/MakeAnIssueTests/TranscriberTests.swift exists
- [x] Sources/MakeAnIssue/AppState.swift contains case transcribing, asrCommandKey, @Published var transcript, onRunTranscription
- [x] Sources/MakeAnIssue/MenuView.swift contains @AppStorage(AppState.asrCommandKey), transcript display, .textSelection(.enabled)
- [x] Tests/MakeAnIssueTests/AppStateTests.swift contains all 5 required test names
- [x] Commit ba82503 exists (Transcriber + TranscriberTests)
- [x] Commit a5c4405 exists (AppState + MenuView switch + AppStateTests)
- [x] Commit 48989af exists (MenuView ASR field + transcript display)
- [x] Full suite: 58 tests, 0 failures
