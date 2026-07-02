---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
plan: 04
subsystem: testing
tags: [swift, xctestcase, applestate, issue-filing, mcp, end-to-end]

# Dependency graph
requires:
  - phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
    provides: IssueFilingRunner, IssueResultParser, AppState .filing state machine, TTS seam, onRunIssueFiling seam

provides:
  - Human-verified end-to-end: real GitHub issues filed via voice -> whisper -> claude+GitHub MCP
  - Regression test pinning corrected parseFailed user-facing status message
  - Fix: parseFailed message no longer falsely implies an issue was filed

affects: [future-verification, uat, v1-release]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "AppStateTests seam injection: onRunIssueFiling stub throwing IssueFilingError cases"

key-files:
  created: []
  modified:
    - Sources/MakeAnIssue/AppState.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift

key-decisions:
  - "parseFailed always means no issue URL was found in CLI output (nothing was filed) — the old 'Issue filed but couldn't parse number' wording was incorrect in every case it fires"
  - "IssueParseError.malformedOutput is declared but never thrown — left as-is (dead enum case, out of scope for v1)"

patterns-established:
  - "Regression test for user-facing error messages: inject throwing stub, assert statusText equals exact string, assert speak seam not called, assert .idle return"

requirements-completed: [ANALYZE-01, ANALYZE-02, ISSUE-01, ISSUE-02, FEEDBACK-01]

# Metrics
duration: 20min
completed: 2026-06-26
status: complete
---

# Phase 04 Plan 04: End-to-End Verification + parseFailed Message Fix Summary

**Full v1 happy path verified end-to-end: two real GitHub issues filed via voice + MCP; negative-check safety confirmed; misleading parseFailed status message corrected and pinned with a regression test.**

## Performance

- **Duration:** ~20 min (continuation executor applying defect fix post-checkpoint)
- **Started:** 2026-06-25T23:07:00Z (Task 1/2 completed in prior session)
- **Completed:** 2026-06-26T01:06:33Z
- **Tasks:** 2 (Task 1 auto + Task 2 human-verify — both completed; plus post-checkpoint defect fix)
- **Files modified:** 2

## Accomplishments

- Task 1 (automated): `swift test` green (110 tests pre-fix); app bundle built via `scripts/build-app.sh`; prerequisites confirmed — claude v2.1.191, Docker 29.6.0 (daemon running), gh authenticated as `milesangelo` with `repo` scope.
- Task 2 (human-verify) PASSED on the happy path: two REAL issues filed end-to-end via voice -> whisper -> claude+GitHub MCP, with the app speaking the correct SMALL human-facing issue number (URL-path parse, not node-id — T-04-03 holds). Filed in pulsedemon/netshooter where the user has WRITE and issues are enabled.
  - Issue #90 "Add a scheduled deploy job for the AWS backend" (2026-06-26T00:48:24Z)
  - Issue #91 "Add a scheduled nightly AWS teardown at 12 midnight EST" (2026-06-26T00:56:39Z)
  - Issue bodies elaborated beyond the literal transcript — ACCEPTED v1 auto-file behavior (not a defect; confirmed locked per plan).
  - Filing latency: ~30s–2min per issue.
- Negative check PASSED (safety): with Docker stopped, the app spoke NO success and filed NO issue (confirmed via `gh issue list` — nothing created at the negative-check time). It showed a status error and returned to Idle.
- Post-checkpoint defect fix: parseFailed status message corrected from misleading "Issue filed but couldn't parse number" to accurate "Couldn't confirm an issue was filed — check GitHub (is Docker running?)".
- Regression test `testParseFailedStatusMessageIsNotMisleading` added; full suite now 111 tests, all green.

## Task Commits

1. **Task 1+2: Build, verify prerequisites, and human-verify end-to-end** — committed in prior session (04-01 through 04-03 commits)
2. **Defect fix: parseFailed message + regression test** — `7941d0d` (fix(04-04))

**Plan metadata:** (docs commit — see Step 7)

## Files Created/Modified

- `Sources/MakeAnIssue/AppState.swift` — One-line fix: `.parseFailed` arm of `message(for: IssueFilingError)` reworded to not imply an issue was filed
- `Tests/MakeAnIssueTests/AppStateTests.swift` — Added `testParseFailedStatusMessageIsNotMisleading` in Phase-04 filing section

## Decisions Made

- `parseFailed` always means no issue URL found in CLI output (nothing filed). The old "Issue filed but couldn't parse number" wording was wrong in 100% of cases it fires because `IssueParseError.malformedOutput` (the only other path to `parseFailed`) is never thrown anywhere in the codebase.
- `IssueParseError.malformedOutput` is declared but never thrown — recorded as a minor follow-up / dead enum case; left as-is (out of scope for v1).
- Accepted v1 auto-file behavior: filed issue bodies may diverge from literal transcript (the CLI investigates the repo and may correct false premises). This was confirmed locked at the human-verify checkpoint.

## Deviations from Plan

### Checkpoint-Surfaced Defect — Fixed in This Plan (per plan spec)

**1. [Rule 1 - Bug] Corrected misleading parseFailed user-facing message**
- **Found during:** Task 2 (human-verify) negative check
- **Issue:** With Docker stopped, the app correctly showed a status error and filed NO issue (safety correct). BUT the status message read "Issue filed but couldn't parse number — check GitHub" even though nothing was filed. Root cause: `IssueParseError.noIssueFound` (thrown when no URL in CLI output) is caught and rethrown as `IssueFilingError.parseFailed`; `IssueParseError.malformedOutput` is never thrown; therefore `parseFailed` ALWAYS means "no URL found / nothing filed" — the "Issue filed" wording was wrong every time it fires.
- **Fix:** Changed the `.parseFailed` arm of `AppState.message(for: IssueFilingError)` to return "Couldn't confirm an issue was filed — check GitHub (is Docker running?)" (exact wording per plan spec). Added regression test `testParseFailedStatusMessageIsNotMisleading` that injects a throwing `onRunIssueFiling` stub, asserts `statusText` equals the new message, asserts `onSpeak` was NOT called (no false success), and asserts `captureState == .idle`.
- **Files modified:** `Sources/MakeAnIssue/AppState.swift`, `Tests/MakeAnIssueTests/AppStateTests.swift`
- **Verification:** `swift test` — 111 tests, 0 failures; app bundle rebuilt via `scripts/build-app.sh`.
- **Committed in:** `7941d0d` (fix(04-04): correct misleading parseFailed status message)

---

**Total deviations:** 1 (defect found at checkpoint, fixed per plan spec)
**Impact on plan:** Fix is surgical (one message string), regression test pins the correct behavior. No scope creep.

## Issues Encountered

None beyond the documented checkpoint defect.

## Known Stubs

None — this plan adds no new UI rendering paths or data sources.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. The one-line message fix is purely cosmetic (user-facing status text). No new threat surface.

## Next Phase Readiness

- Phase 04 is complete. All four plans (04-01 through 04-04) are done.
- The full v1 pipeline is proven end-to-end: push-to-talk capture → bundled-whisper transcription → AI CLI + GitHub MCP issue filing → spoken confirmation with correct human-facing issue number.
- Known follow-up items (out of scope for v1):
  - `IssueParseError.malformedOutput` is a dead enum case — consider removing or adding a throw path in a future cleanup.
  - Phase 3 rework: bundle + sign/notarize `whisper-cli` for distribution (pre-existing deferred item).

---
*Phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation*
*Completed: 2026-06-26*

## Self-Check: PASSED

- [x] `Sources/MakeAnIssue/AppState.swift` modified (parseFailed message)
- [x] `Tests/MakeAnIssueTests/AppStateTests.swift` modified (regression test added)
- [x] Commit `7941d0d` exists: `git log --oneline | grep 7941d0d` -> fix(04-04): correct misleading parseFailed status message (no false "issue filed")
- [x] `swift test`: 111 tests, 0 failures
- [x] App bundle rebuilt via `scripts/build-app.sh`
- [x] Pre-existing `bin/make-an-issue` modification NOT staged or committed
