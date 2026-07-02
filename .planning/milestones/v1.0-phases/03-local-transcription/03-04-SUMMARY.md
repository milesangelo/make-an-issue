---
phase: 03-local-transcription
plan: "04"
subsystem: transcription
status: complete
tags: [transcriber, bundled-whisper, asr, app-state, menu-view, test-rework]
dependency_graph:
  requires: [03-03]
  provides: [TRANSCRIBE-01-invocation, TRANSCRIBE-02]
  affects: [Transcriber.swift, AppState.swift, MenuView.swift]
tech_stack:
  added: []
  patterns:
    - Injectable resourceBase seam for bundle path resolution in swift test environments
    - POSIX single-quote escaping for all three paths (binary, model, wav) in shell command
    - Bundled binary/model resolver methods with FileManager.default.fileExists guard
key_files:
  created: []
  modified:
    - Sources/MakeAnIssue/Transcriber.swift
    - Sources/MakeAnIssue/AppState.swift
    - Sources/MakeAnIssue/MenuView.swift
    - Tests/MakeAnIssueTests/TranscriberTests.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift
decisions:
  - Resolver methods use injectable resourceBase (URL? = nil) seam so tests never need Bundle.main
  - Production default onRunTranscription calls Transcriber.run(wavURL:) with no UserDefaults read
  - message(for: .emptyTranscript) reworded to remove reference to "your command" (no user command)
metrics:
  duration: ~15m
  completed: 2026-06-25
  tasks: 3
  files: 5
requirements: [TRANSCRIBE-01, TRANSCRIBE-02]
---

# Phase 03 Plan 04: Bundled-Whisper Swift Rework Summary

**One-liner:** Rewired Transcriber to invoke the bundled whisper-cli + ggml-small.en.bin via injectable resourceBase resolvers and the generic CLIRunner; deleted ASR Command user-config surface from AppState + MenuView.

---

## What Was Built

### Task 1: Transcriber.swift + TranscriberTests.swift

**Reworked `TranscriberError`** — dropped `emptyCommand` and `missingWavToken`; added `bundledResourcesMissing(detail: String)`; retained `asrFailed`, `asrTimedOut`, `emptyTranscript`. Enum remains `Error, Equatable`.

**Deleted** `prepare(command:wavURL:)` and `run(command:wavURL:)`.

**Added `bundledBinaryURL(resourceBase: URL? = nil) throws -> URL`** — resolves `resourceBase ?? Bundle.main.resourceURL`, throws `bundledResourcesMissing` when the base is nil or `whisper-cli` is absent from the directory.

**Added `bundledModelURL(resourceBase: URL? = nil) throws -> URL`** — same pattern for `ggml-small.en.bin`.

**Added `run(wavURL: URL, resourceBase: URL? = nil) async throws -> String`** — resolves both paths, POSIX-escapes all three (binary, model, wav) with the `replacingOccurrences(of: "'", with: "'\\''")`  idiom, builds `'<bin>' -m '<model>' -f '<wav>' -l en -nt -t 4`, and runs via the unchanged generic `CLIRunner`. The result switch is carried verbatim from the old implementation.

**TranscriberTests** — deleted all 7 `prepare()`-based tests; added:
- `testBundledBinaryURLThrowsWhenResourcesNil` — temp dir without whisper-cli → `bundledResourcesMissing`
- `testBundledModelURLThrowsWhenModelAbsent` — temp dir with whisper-cli but no model → `bundledResourcesMissing`
- `testRunConstructsCorrectCommand` (async) — fake echo `whisper-cli` (executable `#!/bin/sh\necho "$@"`) + stub model; asserts result contains `-m`, `-f`, `-l en`, `-nt`, `-t 4`, and `/tmp/test.wav`

### Task 2: AppState.swift + AppStateTests.swift

- Removed `static let asrCommandKey = "asrCommand"` (D-08)
- Replaced default `onRunTranscription` closure: was `Transcriber.run(command: cmd, wavURL: url)` with a UserDefaults read; now `try await Transcriber.run(wavURL: url)` — no user config read
- Updated `message(for: TranscriberError)`: removed `.emptyCommand` and `.missingWavToken` cases; added `.bundledResourcesMissing(let detail): return "Whisper not bundled — rebuild the app: \(detail)"`;  updated `.emptyTranscript` wording to remove "check your command" reference
- **AppStateTests**: deleted `testEmptyCommandShowsError`; added `testBundledResourcesMissingResetsStateAndSurfacesStatus` (mirrors `testTimeoutResetsState` pattern)

### Task 3: MenuView.swift

Surgical deletions only:
- Deleted `@AppStorage(AppState.asrCommandKey) private var asrCommand: String = ""`
- Deleted the ASR Command `VStack(alignment: .leading, spacing: 4)` block from the Settings `DisclosureGroup`

Settings group now shows exactly: Push-to-Talk Shortcut and CLI Command. `TranscriptCard`, `.transcribing` ActionCard arm, StatusBanner, and `onReceive(UserDefaults.didChangeNotification)` listener are all unchanged.

---

## Final API Surface

```swift
// TranscriberError (reworked)
enum TranscriberError: Error, Equatable {
    case bundledResourcesMissing(detail: String)  // NEW
    case asrFailed(exitCode: Int32, stderr: String)
    case asrTimedOut
    case emptyTranscript
    // emptyCommand, missingWavToken REMOVED
}

// Transcriber (reworked)
struct Transcriber {
    static func bundledBinaryURL(resourceBase: URL? = nil) throws -> URL
    static func bundledModelURL(resourceBase: URL? = nil) throws -> URL
    static func run(wavURL: URL, resourceBase: URL? = nil) async throws -> String
    // prepare(command:wavURL:) and run(command:wavURL:) REMOVED
}

// Command built by run(wavURL:resourceBase:):
// '<bin>' -m '<model>' -f '<wav>' -l en -nt -t 4
```

---

## Verification

```
swift build             Build complete!
swift test              106 tests, 0 failures
  TranscriberTests      3/3 pass (bundledBinaryURL, bundledModelURL, run)
  AppStateTests         36/36 pass (includes new bundledResourcesMissing test)
```

- `grep -c 'bundledResourcesMissing' Transcriber.swift` = 7 ≥ 1 ✓
- `grep -c 'Bundle.main.resourceURL' Transcriber.swift` = 7 ≥ 1 ✓
- `grep -c 'Transcriber.run(wavURL:' AppState.swift` = 1 ≥ 1 ✓
- `grep -c 'bundledResourcesMissing' AppState.swift` = 1 ≥ 1 ✓
- `grep -c 'cliCommandKey' AppState.swift` = 1 ≥ 1 ✓
- `grep -c 'cliCommand' MenuView.swift` = 2 ≥ 1 ✓
- `grep -c 'TranscriptCard' MenuView.swift` = 2 ≥ 1 ✓
- `grep -c 'asrCommand' MenuView.swift` = 0 ✓
- CLIRunner.swift unchanged ✓

Real ~466 MB model never spawned in tests — injectable `resourceBase` seam + `onRunTranscription` stub used throughout.

---

## Deviations from Plan

### Auto-fixed Blocking Issues

**1. [Rule 3 - Blocking] Task 1 compilation requires Task 2 + Task 3 source changes**

- **Found during:** Task 1 verification (`swift test --filter TranscriberTests`)
- **Issue:** Removing `prepare(command:wavURL:)` and the old `run(command:wavURL:)` from Transcriber.swift caused immediate compilation errors in AppState.swift (referencing removed symbols) and MenuView.swift (referencing `asrCommandKey` which was deleted in Task 2). This is an expected and anticipated dependency chain — all three tasks' source changes were necessary to reach a compilable state.
- **Fix:** Applied all three tasks' source changes before testing and committing Task 1. Committed each task separately in sequence after the build was green.
- **Files modified:** AppState.swift, MenuView.swift (ahead of their nominal task order)

No other deviations. The plan executed as written.

---

## Known Stubs

None. All code paths are wired. The production `onRunTranscription` closure calls `Transcriber.run(wavURL:)`, which resolves real bundle paths in the assembled `.app`. Manual end-to-end smoke testing (with the real whisper-cli + model from plan 03-03) is deferred to `/gsd-verify-work`.

---

## Threat Flags

No new threat surface introduced. The three mitigations tracked in the plan's STRIDE register were all implemented:

| Flag | Status |
|------|--------|
| T-03-13: POSIX single-quote escaping for all three paths | Implemented in `run(wavURL:resourceBase:)`; verified by `testRunConstructsCorrectCommand` |
| T-03-14: whisper-cli stdout never parsed/executed | `TranscriptCard` renders as `Text`; stderr separated by CLIRunner (unchanged) |
| T-03-15: 120s timeout via generic CLIRunner | CLIRunner unchanged; `asrTimedOut` thrown and state reset to `.idle` |
| T-03-16: bundledResourcesMissing guard | `bundledBinaryURL`/`bundledModelURL` verify existence; AppState surfaces "rebuild the app" status |

---

## Self-Check: PASSED

All 5 source files found on disk. All 3 task commits present in git history (324b724, 74781f3, 333065b). Full test suite: 106 tests, 0 failures.
