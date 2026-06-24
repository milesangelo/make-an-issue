---
phase: 02-push-to-talk-voice-capture
plan: "01"
subsystem: push-to-talk-state-machine
tags: [keyboard-shortcuts, state-machine, tdd, swift, appstate]
status: complete

dependency_graph:
  requires: []
  provides:
    - CaptureState enum (idle/recording/finished)
    - KeyboardShortcuts.Name.pushToTalk (default Control-Option-I)
    - AppState.captureState @Published property
    - AppState.startRecording() / stopRecording() state machine
    - Injectable recorder seam (onStartRecording/onStopRecording closures)
  affects:
    - Sources/MakeAnIssue/AppState.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift
    - Package.swift

tech_stack:
  added:
    - KeyboardShortcuts 3.0.1 (sindresorhus, SPM)
  patterns:
    - TDD RED/GREEN cycle
    - Injectable no-op seam for unit-testable state machine
    - MainActor.assumeIsolated for callback isolation

key_files:
  created: []
  modified:
    - Package.swift
    - Sources/MakeAnIssue/AppState.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift

decisions:
  - KeyboardShortcuts onKeyDown/onKeyUp callbacks preferred over async events(for:) sequence — matches ObservableObject + @Published pattern in codebase
  - Injectable closure seam (not protocol) chosen for recorder — simpler than a protocol for single-use injection in tests
  - MainActor.assumeIsolated used in shortcut callbacks — cleanest form for @MainActor class accessing self in Swift 6 strict concurrency context

metrics:
  duration: "115 seconds"
  completed: "2026-06-24"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 3
---

# Phase 02 Plan 01: Push-to-Talk State Machine Summary

**One-liner:** KeyboardShortcuts 3.0.1 integrated with injectable push-to-talk state machine (idle/recording/finished) in AppState, default Control-Option-I shortcut, D-04 repeat-ignore guard, TDD verified.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add KeyboardShortcuts SPM dependency | c9cf5cd | Package.swift, Package.resolved |
| 2 (RED) | Add failing state machine tests | 607b44f | Tests/MakeAnIssueTests/AppStateTests.swift |
| 2 (GREEN) | Implement push-to-talk state machine | 49cd588 | Sources/MakeAnIssue/AppState.swift |

## What Was Built

**Package.swift** — Added `KeyboardShortcuts` at `from: "3.0.1"` as a package-level dependency with `.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")` wired into the `MakeAnIssue` target. `Package.resolved` pins the resolved version to 3.0.1 (commit `49c3fc04`).

**AppState.swift** — Extended in-place (no replacement):
- `enum CaptureState: Equatable { case idle; case recording; case finished }` — flat enum adjacent to class
- `extension KeyboardShortcuts.Name { static let pushToTalk }` — default `Control-Option-I` via `initial:` parameter
- `@Published var captureState: CaptureState = .idle` — observable state for menu indicator (Plan 02-02 / 03)
- Injectable recorder seam: `onStartRecording` and `onStopRecording` closures, defaulted to no-ops in `init` — no audio hardware touched by `AppState()` with default arguments
- `startRecording()` — guard `captureState == .idle` (D-04 repeat-ignore), sets `.recording`, invokes start seam
- `stopRecording()` — guard `captureState == .recording`, invokes stop seam, sets `.finished`
- Registered `KeyboardShortcuts.onKeyDown(for: .pushToTalk)` and `onKeyUp` in `init()` (not in a View), wrapped with `MainActor.assumeIsolated`

**AppStateTests.swift** — Extended with 7 new test methods:
- `testInitialCaptureStateIsIdle`
- `testStartRecordingTransitionsToRecording`
- `testSecondStartRecordingWhileRecordingIsIgnored` (D-04)
- `testStopRecordingTransitionsToFinished`
- `testStopRecordingWhileIdleIsNoOp`
- `testStartRecordingInvokesStartSeam`
- `testStopRecordingInvokesStopSeam`

Full suite: 21 tests, 0 failures.

## Verification Results

```
swift package resolve  → exit 0, KeyboardShortcuts 3.0.1 resolved
swift build            → exit 0, Build complete!
swift test --filter AppStateTests → 12 tests, 0 failures
swift test             → 21 tests, 0 failures
```

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| Closure seam over protocol | Single-use injection; closures are simpler than a full protocol definition for this use case |
| `MainActor.assumeIsolated` in KeyboardShortcuts callbacks | AppState is `@MainActor`; KeyboardShortcuts 3.0.1 callbacks may not be dispatched on main actor; `assumeIsolated` is the correct compile-clean form |
| `startRecording()` guard duplicates onKeyDown guard | Defense-in-depth: the public method is safely callable directly (e.g. from tests or future code) without triggering repeat-state corruption |

## Deviations from Plan

### Package.swift parameter ordering

**Found during:** Task 1  
**Issue:** The plan's pattern placed `dependencies:` before `products:` in the Package initializer, but the Swift Package Description compiler enforced that `products` must precede `dependencies` in Swift 5.10 parameter order.  
**Fix:** Moved `dependencies:` array to after `products:`, matching the required PackageDescription API order.  
**Files modified:** Package.swift  
**Type:** Rule 3 (auto-fix blocking issue)

## Known Stubs

None. Plan 02-01 establishes pure state machine logic with no-op seam defaults. The seam is intentionally a no-op placeholder; Plan 02-02 will wire the real `AudioRecorder` without modifying this plan's methods — this is the designed handoff, not a stub.

## Threat Flags

None. No new network endpoints, auth paths, or file access patterns introduced. `KeyboardShortcuts` uses Carbon `RegisterEventHotKey` (no Accessibility permission required). The SPM package was verified in the Package Legitimacy Audit (verdict OK, author Sindre Sorhus).

## Self-Check: PASSED

- [x] Package.swift modified: `/Users/milesangelo/source/make-an-issue/Package.swift` — exists
- [x] AppState.swift modified: `/Users/milesangelo/source/make-an-issue/Sources/MakeAnIssue/AppState.swift` — exists
- [x] AppStateTests.swift modified: `/Users/milesangelo/source/make-an-issue/Tests/MakeAnIssueTests/AppStateTests.swift` — exists
- [x] Commit c9cf5cd: feat(02-01): add KeyboardShortcuts SPM dependency — verified in git log
- [x] Commit 607b44f: test(02-01): add failing tests (RED) — verified in git log
- [x] Commit 49cd588: feat(02-01): implement push-to-talk state machine (GREEN) — verified in git log
- [x] 21 tests pass, 0 failures
