---
phase: 01-menu-bar-app-repo-bound-launch
plan: 02
subsystem: launcher-handoff
tags: [swift, appkit, shell, launchservices, json]
requires:
  - phase: 01-01
    provides: SwiftUI menu-bar app shell and generated .app bundle
provides:
  - Repo-local launcher command
  - Canonical launch request JSON schema
  - Application Support request persistence and one-shot consume
  - AppKit startup and reopen request consumption
affects: [phase-1-launch, repo-binding, app-state]
tech-stack:
  added: [AppKit NSApplicationDelegate, POSIX shell launcher]
  patterns: [Application Support handoff file, lifecycle delegate consumes latest request]
key-files:
  created:
    - bin/make-an-issue
    - Sources/MakeAnIssue/LaunchRequest.swift
    - Sources/MakeAnIssue/LaunchRequestStore.swift
    - Sources/MakeAnIssue/AppDelegate.swift
    - Tests/MakeAnIssueTests/LaunchRequestStoreTests.swift
  modified:
    - Sources/MakeAnIssue/MakeAnIssueApp.swift
    - Sources/MakeAnIssue/AppState.swift
key-decisions:
  - "Use a JSON handoff file in Application Support so shell launch and GUI lifecycle stay decoupled."
  - "Use LaunchServices open on the generated app bundle to activate an existing instance."
patterns-established:
  - "Launcher writes cwd plus integer createdAtUnixSeconds before opening the app."
  - "AppDelegate consumes and deletes the latest launch request on startup and reopen."
requirements-completed: [LAUNCH-01]
duration: 4 min
completed: 2026-06-23
status: complete
---

# Phase 1 Plan 02: Repo-Local Launcher Handoff Summary

**Repo-local shell launcher with Application Support JSON cwd handoff consumed by the running menu-bar app**

## Performance

- **Duration:** 4 min
- **Started:** 2026-06-24T04:47:00Z
- **Completed:** 2026-06-24T04:50:49Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments

- Added `LaunchRequest` with the canonical `cwd` and `createdAtUnixSeconds` JSON schema.
- Added `LaunchRequestStore` with injectable test directory, production Application Support path, atomic writes, one-shot consume, and malformed-file cleanup.
- Added executable `bin/make-an-issue` that captures `pwd -P`, writes the handoff JSON, and opens `.build/MakeAnIssue.app`.
- Added `AppDelegate` lifecycle hooks for startup and reopen request consumption.
- Wired launch requests into the shared `AppState` for display and later repo binding.

## Task Commits

1. **Task 1 RED: Persist launch cwd requests tests** - `84051f7` (test)
2. **Task 1 GREEN: Persist launch cwd requests** - `1369c95` (feat)
3. **Task 2: Add the repo-local launcher command** - `6e9d53a` (feat)
4. **Task 3: Consume launch requests on startup and reopen** - `315ba2b` (feat)

## Files Created/Modified

- `bin/make-an-issue` - Repo-local launcher command.
- `Sources/MakeAnIssue/LaunchRequest.swift` - Codable launch handoff payload.
- `Sources/MakeAnIssue/LaunchRequestStore.swift` - Request file persistence and consume helper.
- `Sources/MakeAnIssue/AppDelegate.swift` - AppKit startup/reopen lifecycle adapter.
- `Sources/MakeAnIssue/MakeAnIssueApp.swift` - Delegate adaptor and shared state registration.
- `Sources/MakeAnIssue/AppState.swift` - Launch request handler storing latest cwd.
- `Tests/MakeAnIssueTests/LaunchRequestStoreTests.swift` - Persistence and fixture tests.

## Decisions Made

- Kept launch handoff to a small local file instead of command-line arguments or custom URL events.
- Added test-only launcher overrides for request directory and open command so launch behavior is verifiable without touching the user support directory or opening the GUI.

## Deviations from Plan

None - plan executed exactly as written.

---

**Total deviations:** 0 auto-fixed.  
**Impact on plan:** No scope change.

## Issues Encountered

- Human visual verification of same-instance menu activation was not performed in this non-GUI execution flow. Automated lifecycle, shell, and handoff checks passed.

## Verification

- `swift test --filter LaunchRequestStoreTests` - passed
- `swift test --filter LaunchRequestStoreTests/testDecodesShellWrittenLaunchRequestFixture` - passed
- `swift test --filter LaunchRequestStoreTests/testConsumesShellWrittenLaunchRequestFixture` - passed
- `swift test` - passed
- `swift build` - passed
- `sh -n bin/make-an-issue` - passed
- `test -x bin/make-an-issue` - passed
- `rg 'pwd -P' bin/make-an-issue` - passed
- `rg 'createdAtUnixSeconds' bin/make-an-issue` - passed
- `rg '/usr/bin/open' bin/make-an-issue` - passed
- `rg 'launch-request\.json' bin/make-an-issue` - passed
- Temporary request-directory smoke command - passed
- `rg 'NSApplicationDelegateAdaptor' Sources/MakeAnIssue/MakeAnIssueApp.swift` - passed
- `rg 'applicationShouldHandleReopen|applicationDidFinishLaunching' Sources/MakeAnIssue/AppDelegate.swift` - passed
- `rg 'handleLaunchRequest' Sources/MakeAnIssue/AppState.swift Sources/MakeAnIssue/AppDelegate.swift` - passed
- `./scripts/build-app.sh` - passed

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Ready for Plan 01-03 to resolve the launch cwd to a git root and render the bound repository.

---
*Phase: 01-menu-bar-app-repo-bound-launch*
*Completed: 2026-06-23*
