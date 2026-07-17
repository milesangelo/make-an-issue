---
phase: 08-editable-system-prompt-finding-06-cleanup
plan: 01
subsystem: ui
tags: [swiftui, appstate, menubar, finding-06, cleanup]

requires:
  - phase: 07-appkit-status-item-ui-settings-window-shell
    provides: Settings window shell hosting the push-to-talk Recorder; D-04 explicitly deferred the "CLI Command" field removal/relocation to Phase 8
provides:
  - MenuView popover with no "CLI Command" field and no settings DisclosureGroup (false affordance removed)
  - AppState.instructionsKey persistence-key constant for Plan 03's editable-instructions @AppStorage binding
affects: [08-02-buildPrompt-restructure, 08-03-SettingsView-instructions-tab]

tech-stack:
  added: []
  patterns: ["@AppStorage persistence-key constant co-located on AppState, mirrored by a consumer view binding"]

key-files:
  created: []
  modified:
    - Sources/MakeAnIssue/MenuView.swift
    - Sources/MakeAnIssue/AppState.swift

key-decisions:
  - "instructionsKey = \"instructions\" added to AppState, mirroring the removed cliCommandKey template (D-05)"

patterns-established:
  - "Doc-comment convention: persistence-key constants carry a cross-reference to their consumer @AppStorage binding (e.g. 'must match @AppStorage in SettingsView') plus a (D-xx) decision-ID annotation"

requirements-completed: [SETTINGS-05]

duration: 8min
completed: 2026-07-01
status: complete
---

# Phase 8 Plan 1: FINDING-06 Cleanup Summary

**Removed the orphaned, non-functional "CLI Command" field and its DisclosureGroup from the menu-bar popover, and swapped `AppState.cliCommandKey` for the new `AppState.instructionsKey` persistence key that Plan 03's editable-instructions tab will bind to.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-01T13:54:00Z (approx.)
- **Completed:** 2026-07-01T13:56:17Z
- **Tasks:** 2 completed
- **Files modified:** 2

## Accomplishments
- Deleted the dead `@AppStorage(AppState.cliCommandKey) private var cliCommand` binding, the orphaned `isSettingsExpanded` state, and the entire now-empty `DisclosureGroup` + its introducing `Divider()` from `MenuView.swift` — resolving FINDING-06 / SETTINGS-05's false affordance.
- Removed `AppState.cliCommandKey` entirely (no source references remain) and added `AppState.instructionsKey = "instructions"` with a doc comment following the existing cross-reference convention, pointing at the Plan 03 `SettingsView` consumer and carrying a `(D-05)` decision-ID annotation.
- Confirmed `updateShortcutText()`, `shortcutText`, `shouldShowStatusBanner`, `ActionCard`, and `ShortcutPillView` were untouched — deletion was scoped exactly to the D-01/D-01a orphaned block.

## Task Commits

Each task was committed atomically:

1. **Task 1: Remove the orphaned "CLI Command" field + its DisclosureGroup from MenuView (D-01, D-01a)** - `ea51cc5` (fix)
2. **Task 2: Remove cliCommandKey and add instructionsKey in AppState (D-01, D-05)** - `dc29b1a` (feat)

**Plan metadata:** (recorded below)

## Files Created/Modified
- `Sources/MakeAnIssue/MenuView.swift` - Removed `cliCommand` `@AppStorage` binding, `isSettingsExpanded` state, and the entire "Settings" `DisclosureGroup` (with its introducing `Divider()`)
- `Sources/MakeAnIssue/AppState.swift` - Replaced `cliCommandKey` constant with `instructionsKey = "instructions"`

## Decisions Made
- `instructionsKey = "instructions"` added to `AppState`, mirroring the removed `cliCommandKey` template exactly (same doc-comment cross-reference convention, now pointing at `SettingsView` instead of `MenuView`) — per D-05.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `AppState.instructionsKey` is in place and ready for Plan 03's `@AppStorage(AppState.instructionsKey)` binding in `SettingsView`.
- `AppState.cliCommandKey` is fully gone from the source tree — confirmed via grep (only a doc-comment prose mention of the former name remains, no symbol reference) and via a green `swift build`.
- Full `swift test` suite (137 tests) passes; `swift test --filter AppStateTests` (54 tests) passes.
- No blockers for Plan 02 (`buildPrompt()` restructure) or Plan 03 (`SettingsView` Instructions tab).

## Self-Check: PASSED

- `[ -f Sources/MakeAnIssue/MenuView.swift ]` → FOUND
- `[ -f Sources/MakeAnIssue/AppState.swift ]` → FOUND
- `git log --oneline --all --grep="08-01"` → returns `ea51cc5` and `dc29b1a`
- `grep -n "isSettingsExpanded\|cliCommand\|DisclosureGroup" Sources/MakeAnIssue/MenuView.swift` → no matches (clean removal)
- `grep -n "instructionsKey" Sources/MakeAnIssue/AppState.swift` → `static let instructionsKey = "instructions"` present
- `swift build` → Build complete, no errors
- `swift test --filter AppStateTests` → 54/54 passed
- `swift test` (full suite) → 137/137 passed

---
*Phase: 08-editable-system-prompt-finding-06-cleanup*
*Completed: 2026-07-01*
