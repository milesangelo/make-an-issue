---
phase: 06-cancellation-stop-control
plan: "01"
subsystem: tests
status: complete
tags: [process-groups, signals, cancellation, testing, empirical-gate]
dependency_graph:
  requires: []
  provides:
    - empirical-A1-A2-validation
    - cancel-test-scaffolds
  affects:
    - 06-02 (cancel implementation — gates on A1/A2)
    - 06-03 (AppState cancel — scaffolds are the test contract)
tech_stack:
  added: []
  patterns:
    - POSIX process-group signals (getpgid, getpgrp, kill with negative PID)
    - ContinuousClock deadline polling in async tests
    - XCTSkip scaffolds for pending implementation waves
key_files:
  created: []
  modified:
    - Tests/MakeAnIssueTests/CLIRunnerTests.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift
decisions:
  - "A1 confirmed: Foundation.Process places each spawned /bin/zsh child in its own process group (getpgid(child)==child) — kill(-pgid) is safe"
  - "A2 confirmed: child group is distinct from the test process group (getpgid(child)!=getpgrp()) — group-directed signal cannot reach the app"
  - "Negative-PID reap confirmed: kill(-pid, SIGTERM) reaps the group within 3s on macOS — mechanism is valid"
  - "Six cancel scaffolds committed before implementation — test names locked per RESEARCH.md Validation Architecture"
metrics:
  duration: "~4 minutes"
  completed: "2026-06-29"
  tasks_completed: 2
  files_modified: 2
requirements:
  - CANCEL-01
  - CANCEL-02
  - CANCEL-03
---

# Phase 06 Plan 01: Wave-0 Verification Floor Summary

**One-liner:** Empirical POSIX process-group gate (A1/A2 confirmed, negative-PID reap confirmed) plus compile-safe XCTSkip scaffolds for six cancel behaviors — kill(-pgid) approach is validated safe to build on.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Empirical process-group gate (A1/A2) | cedd11c | CLIRunnerTests.swift |
| 2 | Compile-safe XCTSkip scaffolds | b2e121c | CLIRunnerTests.swift, AppStateTests.swift |

## Verification Results

- `swift test --filter CLIRunnerTests.testSpawnedChildIsProcessGroupLeader` — exits 0 (A1/A2 confirmed)
- `swift test --filter CLIRunnerTests.testNegativePIDSignalReapsProcessGroup` — exits 0 (group reap confirmed)
- `swift test` — 134 passed, 6 skipped, 0 failures
- `grep -c "getpgid" CLIRunnerTests.swift` — 3 (A1 leader check + A2 app-group check + negated-PID reap poll)
- `grep -c "func testCancel" CLIRunnerTests.swift` — 2
- `grep -c "func testCancel" AppStateTests.swift` — 4
- `grep -c "XCTSkip" CLIRunnerTests.swift` — 2
- `grep -c "XCTSkip" AppStateTests.swift` — 4
- `git diff --name-only HEAD~2 HEAD` — only test files (no Sources/ modifications)

## Phase 6 Gate: PASSED

Both empirical tests pass:
- **A1 (getpgid(child) == child):** Foundation.Process places each spawned `/bin/zsh -lc …` child in its own process group. The `kill(-pgid, …)` approach is safe.
- **A2 (getpgid(child) != getpgrp()):** The child's group is distinct from the test/app process group. A group-directed signal will not hit the app.
- **Negative-PID reap:** `kill(-pid, SIGTERM)` reaps the spawned group within 3 seconds. The mechanism works on this platform.

The kill(-pgid) approach assumed by 06-02/03/04 is validated. Phase 6 may proceed to implementation.

## New Test Methods

### CLIRunnerTests.swift (Task 1 — real, passing)
- `testSpawnedChildIsProcessGroupLeader` — asserts getpgid(child)==child (A1) AND getpgid(child)!=getpgrp() (A2)
- `testNegativePIDSignalReapsProcessGroup` — sends kill(-pid, SIGTERM), polls until ESRCH

### CLIRunnerTests.swift (Task 2 — scaffolds)
- `testCancelKillsProcessGroup` — XCTSkip, fleshed out in 06-02
- `testCancelAndExitBoundaryResolvesExactlyOnce` — XCTSkip, fleshed out in 06-02

### AppStateTests.swift (Task 2 — scaffolds)
- `testCancelJobIdTransitionsToCancel` — XCTSkip, fleshed out in 06-03
- `testCancelAnnouncementDeferredDuringRecording` — XCTSkip, fleshed out in 06-03
- `testCancelAllCancelsEveryInFlightJob` — XCTSkip, fleshed out in 06-03
- `testCancelledJobRetainedInJobsList` — XCTSkip, fleshed out in 06-03

## Deviations from Plan

None — plan executed exactly as written. Added `import Darwin` explicitly to CLIRunnerTests.swift for unambiguous POSIX symbol access (the plan noted Darwin is transitively available; explicit import is safer and is not a new dependency).

## Threat Flags

None. This plan only modifies test files; no new network endpoints, auth paths, file access patterns, or schema changes were introduced.

## Self-Check: PASSED
