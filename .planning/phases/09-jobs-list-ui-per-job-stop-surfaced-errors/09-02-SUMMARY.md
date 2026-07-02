---
phase: 09-jobs-list-ui-per-job-stop-surfaced-errors
plan: 02
subsystem: ui
tags: [swift, swiftui, appstate, jobs-model, menubar-popover]

# Dependency graph
requires:
  - phase: 09-jobs-list-ui-per-job-stop-surfaced-errors
    provides: "Plan 09-01's dismiss(jobID:)/clearFinished()/message(for:)/JobRowStyle logic layer"
provides:
  - "JobsSection — the rendered 'FILING JOBS (N)' popover section, hidden when jobs[] is empty, newest-first, fixed-height scroll"
  - "JobRow — per-FilingJobState row (.filing/.done/.failed/.cancelled) with state-correct controls"
  - "DismissButton, ClearAllButton, TranscriptSnippet — leaf controls/views composing JobRow/JobsSection"
  - "JobsSection(appState:) composed into MenuView.body after TranscriptCard"
affects: [v1.1 milestone completion — this was the last unbuilt UI surface]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TranscriptCard's ScrollView + card-chrome idiom (.padding/.background/.cornerRadius/.overlay) reused for JobsSection's fixed-height (180pt) job list"
    - "Explicit appState pass-through (not @EnvironmentObject) on leaf rows (JobRow, DismissButton, ClearAllButton), matching ActionCard's existing convention"
    - "Https-only NSWorkspace.shared.open guard: done-row open is gated through JobRowStyle.openableIssueURL(_:) before any URL open call — never opens a raw job.result.url string"

key-files:
  created: []
  modified:
    - Sources/MakeAnIssue/MenuView.swift

key-decisions:
  - "180pt fixed max-height for JobsSection's ScrollView, per 09-RESEARCH Open Question 1 (UAT-tunable constant) — confirmed correct during human verification, no adjustment needed"
  - "Clear-all control only renders when appState.jobs.contains(where: { $0.state != .filing }) — avoids showing a no-op button when only in-flight jobs exist"
  - "No automated rendered-view tests added (no ViewInspector/SnapshotTesting in this project, consistent with every prior phase's UI) — verification is the human-verify UAT checkpoint (Task 3)"

patterns-established:
  - "Human-verify checkpoint as the sole verification path for SwiftUI view composition, given no rendered-view test harness in Package.swift"

requirements-completed: [JOBS-01, JOBS-02, RESIL-01]

# Metrics
duration: ~15min (2 auto tasks + human-verify checkpoint)
completed: 2026-07-02
status: complete
---

# Phase 09 Plan 02: Filing Jobs List UI Summary

**Live "Filing Jobs" popover section rendering `AppState.jobs` via `JobsSection`/`JobRow`, with per-state Stop/✕/Clear-all controls wired to the Plan 09-01 logic layer — the last visible piece of the v1.1 milestone.**

## Performance

- **Duration:** ~15 min (2 auto tasks + human-verify checkpoint)
- **Tasks:** 3 (2 auto, 1 checkpoint:human-verify)
- **Files modified:** 1 (Sources/MakeAnIssue/MenuView.swift)

## Accomplishments

- `JobRow`, `DismissButton`, and `TranscriptSnippet` leaf views added, covering all four `FilingJobState` cases with strict control separation: `.filing` rows show `ActivitySpinner` + "Filing…" + a "Stop" button calling `appState.cancel(jobID:)` and no ✕; terminal rows (`.done`/`.failed`/`.cancelled`) show a `DismissButton` (✕ → `appState.dismiss(jobID:)`) and no Stop (JOBS-02, D-05).
- `.done` rows open the filed issue only through the `JobRowStyle.openableIssueURL(_:)` https guard before calling `NSWorkspace.shared.open` — never on a raw `job.result.url` string (D-10, T-09-03 mitigated).
- `.failed` rows render `AppState.message(for:)`'s mapped error text (no re-authored strings, D-09) plus an expandable `TranscriptSnippet` (tap to toggle full transcript, RESIL-01/D-08).
- `JobsSection` + `ClearAllButton` added and composed as the last item of `MenuView.body`'s VStack, after `TranscriptCard`: the whole section (including Clear-all) collapses to nothing when `appState.jobs.isEmpty` (D-12); jobs render newest-first via `.reversed()` inside a 180pt fixed-height `ScrollView` (D-03); Clear-all calls `appState.clearFinished()` and only appears when a terminal job exists.
- Human-verify UAT (Task 3) **APPROVED** by the operator — all 6 checks passed: empty state hides the section entirely; filing row shows spinner + Stop with no ✕, Stop transitions to a cancelled row with ✕ and no Stop; done row's `#N` opens the correct GitHub issue in the browser; failed row shows the mapped message + expandable transcript and persists until dismissed; newest job renders on top with the list scrolling inside a fixed-height area; Clear-all removes all terminal rows while an in-flight `.filing` job remains untouched.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add JobRow, DismissButton, TranscriptSnippet leaf views** - `3cf5ed7` (feat)
2. **Task 2: Add JobsSection + ClearAllButton, compose into MenuView.body** - `65397df` (feat)
3. **Task 3: Human-verify the rendered Filing Jobs section (UAT)** - manual checkpoint, no commit (no code changes) — **APPROVED** by operator

**Plan metadata:** (this commit)

## Files Created/Modified

- `Sources/MakeAnIssue/MenuView.swift` - Added `JobRow`, `DismissButton`, `TranscriptSnippet`, `JobsSection`, `ClearAllButton`; composed `JobsSection(appState:)` into `MenuView.body` after `TranscriptCard`

## Decisions Made

- 180pt fixed-height `ScrollView` for the jobs list, matching `TranscriptCard`'s card chrome — confirmed adequate during UAT (no resize requested).
- Clear-all rendered conditionally (only when a non-`.filing` job exists) rather than always-present-but-disabled, keeping the header simple.

## Deviations from Plan

None - plan executed exactly as written. Both automated tasks compiled and passed on the first implementation pass; the human-verify checkpoint was approved without any noted regressions.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Full `swift test` suite (155 tests) is green; `swift build` compiles clean. No new automated rendering tests were added for this plan — rendered-view behavior for `JobsSection`/`JobRow` is UAT-verified only, consistent with every prior phase's UI (no ViewInspector/SnapshotTesting in this project).
- This was the last unbuilt UI surface for the v1.1 "Concurrent Filing & Control" milestone (JOBS-01, JOBS-02, RESIL-01 now all satisfied). No blockers carried forward from Phase 09.

---
*Phase: 09-jobs-list-ui-per-job-stop-surfaced-errors*
*Completed: 2026-07-02*

## Self-Check: PASSED

Verified via `grep`: `MenuView.swift` declares `struct JobsSection`, `struct JobRow`, `struct DismissButton`, `struct ClearAllButton`, `struct TranscriptSnippet`; `JobsSection(appState: appState)` present in `MenuView.body`; done-row open path calls `JobRowStyle.openableIssueURL(result.url)` before `NSWorkspace.shared.open(url)`. Both task commits (3cf5ed7, 65397df) verified present in `git log --oneline`. No source files were modified during this continuation (working tree shows no diffs to Sources/).
