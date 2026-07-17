---
phase: 09-jobs-list-ui-per-job-stop-surfaced-errors
plan: 01
subsystem: ui
tags: [swift, swiftui, xctest, appstate, jobs-model]

# Dependency graph
requires:
  - phase: 06-cancellation-and-quit-teardown
    provides: FilingJobState (.filing/.done/.failed/.cancelled), cancel(jobID:)/cancelAll() on AppState
  - phase: 08-editable-system-prompt
    provides: AppState @MainActor structure, existing message(for:) mapper pattern
provides:
  - "AppState.dismiss(jobID:) and AppState.clearFinished() — terminal-only jobs[] mutations"
  - "AppState.message(for: IssueFilingError) exposed (no longer private) for view consumption"
  - "JobRowStyle enum: iconName(for:), tintColor(for:), openableIssueURL(_:) — pure per-state styling + https URL guard"
affects: [09-jobs-list-ui-per-job-stop-surfaced-errors plan 02 (MenuView JobsSection/JobRow/DismissButton/ClearAllButton)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure namespace enum (no cases, nonisolated statics) for view styling logic that needs unit-test coverage without a rendered-view test harness"
    - "Explicit `$0.state != .filing` predicate (not a negated helper) for terminal-job mutations, guarding against future FilingJobState cases being silently swept"

key-files:
  created:
    - Sources/MakeAnIssue/JobRowStyle.swift
    - Tests/MakeAnIssueTests/JobRowStyleTests.swift
  modified:
    - Sources/MakeAnIssue/AppState.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift

key-decisions:
  - "dismiss(jobID:) and clearFinished() never call task?.cancel() — dismissal is not cancellation (D-05/D-06)"
  - "message(for: IssueFilingError) access level widened from private to internal (default) only — no public, matching MenuView.swift's same-target reachability (CLAUDE.md: minimum widening)"
  - "JobRowStyle kept non-@MainActor so its statics are nonisolated and callable from tests without hopping the main actor"
  - "openableIssueURL admits only https (case-insensitive scheme match) — defense-in-depth on AI-CLI-stdout-derived URL strings, ahead of Plan 09-02's NSWorkspace.shared.open call site"

patterns-established:
  - "Pure logic layer (JobRowStyle) split out from an un-inspectable SwiftUI view body specifically for automated coverage, given no ViewInspector/SnapshotTesting in this project"

requirements-completed: [JOBS-01, RESIL-01]

# Metrics
duration: 8min
completed: 2026-07-02
status: complete
---

# Phase 09 Plan 01: Jobs List Logic Surface Summary

**Terminal-only job removal (`dismiss`/`clearFinished`), an exposed error-message mapper, and a pure `JobRowStyle` icon/color/https-URL-guard namespace — the fully-unit-tested logic layer Plan 09-02's jobs-list view will render.**

## Performance

- **Duration:** ~8 min
- **Tasks:** 3
- **Files modified:** 4 (2 created, 2 modified)

## Accomplishments

- `AppState.dismiss(jobID:)` and `AppState.clearFinished()` added — the only two paths that ever remove a job from `jobs[]`; both scope strictly to non-`.filing` jobs and never call `task?.cancel()`, so an in-flight filing can never be silently dropped from the list (D-05/D-06, RESIL-01).
- `AppState.message(for: IssueFilingError)` — previously `private` and dead code (zero call sites) — is now reachable from the target, unlocking the jobs-list failed-row view's error text in Plan 09-02. No string was re-authored; the 5-case mapping is now pinned by a test (D-09).
- New `JobRowStyle` enum provides `iconName(for:)`, `tintColor(for:)` (distinct SF Symbol + color per `FilingJobState`, JOBS-01/D-01) and `openableIssueURL(_:)`, an https-only scheme guard that is the D-10 defense-in-depth check Plan 09-02 will call before `NSWorkspace.shared.open` on an AI-CLI-stdout-derived URL (T-09-02).

## Task Commits

Each task was committed atomically:

1. **Task 1: Add dismiss(jobID:) and clearFinished() to AppState with unit tests** - `2c08d71` (feat)
2. **Task 2: Expose message(for: IssueFilingError) and pin its per-case strings with a test** - `a47c4da` (feat)
3. **Task 3: Add pure JobRowStyle mapper (icon, color, https URL guard) with unit tests** - `a5d3749` (feat)

**Plan metadata:** (pending — see final commit below)

## Files Created/Modified

- `Sources/MakeAnIssue/JobRowStyle.swift` - New pure namespace enum: per-state icon/tint mapping + https-only URL open guard
- `Tests/MakeAnIssueTests/JobRowStyleTests.swift` - Unit tests for icon distinctness, color mapping, and URL scheme rejection (http/javascript/file/garbage)
- `Sources/MakeAnIssue/AppState.swift` - Added `dismiss(jobID:)`/`clearFinished()`; dropped `private` on `message(for: IssueFilingError)`
- `Tests/MakeAnIssueTests/AppStateTests.swift` - 5 new tests: 4 for dismiss/clearFinished, 1 pinning the 5-case error-message mapping

## Decisions Made

- Split Task 1/Task 2 into two separate atomic commits even though both touch `AppState.swift`/`AppStateTests.swift`, by reverting and reapplying each task's edit in isolation (git commit-per-task discipline preserved despite file overlap).
- No `FilingJob` timestamp field added — jobs are already append-ordered in `jobs[]`, so terminal-job removal needs no extra state (plan's Pitfall 3 guidance followed).

## Deviations from Plan

None - plan executed exactly as written. No auto-fixes were needed; all three tasks compiled and passed on the first implementation pass.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 09-02 can now build `JobsSection`/`JobRow`/`DismissButton`/`ClearAllButton`/`TranscriptSnippet` in `MenuView.swift` directly on top of `dismiss(jobID:)`, `clearFinished()`, `AppState.message(for:)`, and `JobRowStyle` — no further AppState/logic changes anticipated for Plan 09-02.
- Full `swift test` suite (155 tests) is green; `swift build` compiles clean.
- No blockers.

---
*Phase: 09-jobs-list-ui-per-job-stop-surfaced-errors*
*Completed: 2026-07-02*

## Self-Check: PASSED

All created/modified files found on disk; all 3 task commits (2c08d71, a47c4da, a5d3749) verified present in git log.
