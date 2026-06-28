---
phase: 01-menu-bar-app-repo-bound-launch
plan: 01
subsystem: macos-app-shell
tags: [swift, swiftui, menubarextra, plist, spm]
requires: []
provides:
  - Native Swift Package executable target and test target
  - No-Dock menu-bar app bundle metadata
  - Window-style MenuBarExtra app entry
  - Shared observable app state and initial menu content
  - Repeatable local .app bundle build script
affects: [phase-1-launch, menu-ui, app-state]
tech-stack:
  added: [Swift Package Manager, SwiftUI MenuBarExtra]
  patterns: [StateObject-owned AppState, EnvironmentObject-fed MenuView, script-built local app bundle]
key-files:
  created:
    - Package.swift
    - Resources/Info.plist
    - Sources/MakeAnIssue/MakeAnIssueApp.swift
    - Sources/MakeAnIssue/AppState.swift
    - Sources/MakeAnIssue/MenuView.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift
    - scripts/build-app.sh
  modified: []
key-decisions:
  - "Use SwiftUI MenuBarExtra with .window style for the v1 menu-bar shell."
  - "Build a local .build/MakeAnIssue.app bundle from SwiftPM output for launcher activation."
patterns-established:
  - "One shared AppState object is owned at the app entry point and injected into menu UI."
  - "Bundle metadata lives in Resources/Info.plist and is copied by scripts/build-app.sh."
requirements-completed: [LAUNCH-03]
duration: 8 min
completed: 2026-06-23
status: complete
---

# Phase 1 Plan 01: Menu-Bar App Shell Summary

**SwiftUI menu-bar app shell with LSUIElement bundle metadata, shared app state, and repeatable local app bundle generation**

## Performance

- **Duration:** 8 min
- **Started:** 2026-06-24T04:38:00Z
- **Completed:** 2026-06-24T04:46:36Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments

- Created a Swift Package executable target named `MakeAnIssue` with a focused test target.
- Added `Resources/Info.plist` with `LSUIElement` enabled for no-Dock menu-bar behavior.
- Added a SwiftUI `MenuBarExtra` app entry using `.menuBarExtraStyle(.window)`.
- Added `AppState` and `MenuView` so the menu renders status and initial repository state from shared app state.
- Added `scripts/build-app.sh` to generate `.build/MakeAnIssue.app`.

## Task Commits

1. **Task 1: Create the Swift package and app bundle metadata** - `6f46712` (feat)
2. **Task 2 RED: Add failing app state initial tests** - `7040075` (test)
3. **Task 2 GREEN: Add status state and menu content** - `54e11cf` (feat)

## Files Created/Modified

- `Package.swift` - Swift Package manifest for the executable and test target.
- `Resources/Info.plist` - App bundle metadata with `LSUIElement` enabled.
- `Sources/MakeAnIssue/MakeAnIssueApp.swift` - SwiftUI app entry and window-style `MenuBarExtra`.
- `Sources/MakeAnIssue/AppState.swift` - Observable app status and initial repository display state.
- `Sources/MakeAnIssue/MenuView.swift` - Menu-bar window content driven by `AppState`.
- `Tests/MakeAnIssueTests/AppStateTests.swift` - Unit tests for initial app state.
- `scripts/build-app.sh` - Repeatable local app bundle build script.

## Decisions Made

- Used a SwiftPM executable plus script-created app bundle to keep v1 setup simple and repo-local.
- Kept initial menu content limited to status and repository display text, with no repo-switching controls.

## Deviations from Plan

None - plan executed exactly as written.

---

**Total deviations:** 0 auto-fixed.  
**Impact on plan:** No scope change.

## Issues Encountered

- SwiftPM commands needed normal user cache access outside the sandbox; rerunning with approved elevated Swift/build prefixes resolved the environment issue.

## Verification

- `swift test --filter AppStateTests` - passed
- `swift build` - passed
- `plutil -extract LSUIElement raw Resources/Info.plist` - returned `true`
- `rg 'menuBarExtraStyle\(\.window\)' Sources/MakeAnIssue/MakeAnIssueApp.swift` - passed
- `sh -n scripts/build-app.sh` - passed
- `test -x scripts/build-app.sh` - passed
- `./scripts/build-app.sh` - passed
- `test -f .build/MakeAnIssue.app/Contents/MacOS/MakeAnIssue` - passed
- `test -f .build/MakeAnIssue.app/Contents/Info.plist` - passed

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

Ready for Plan 01-02 to add the repo-local launcher command and launch request handoff.

---
*Phase: 01-menu-bar-app-repo-bound-launch*
*Completed: 2026-06-23*
