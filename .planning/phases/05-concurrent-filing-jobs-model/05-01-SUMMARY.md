---
phase: "05"
plan: "01"
subsystem: concurrent-filing-jobs-model
status: complete
tags: [concurrency, jobs-model, swift, refactor]
dependency_graph:
  requires: []
  provides: [FilingJob.swift, AppState.jobs, spawnFilingJob, announce/flush helpers]
  affects: [AppState.swift, MenuView.swift, AppStateTests.swift]
tech_stack:
  added: []
  patterns: [concurrent-Task-per-job, announce-defer-queue, tdd-red-green]
key_files:
  created:
    - Sources/MakeAnIssue/FilingJob.swift
    - Tests/MakeAnIssueTests/FilingJobTests.swift
  modified:
    - Sources/MakeAnIssue/AppState.swift
    - Sources/MakeAnIssue/MenuView.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift
decisions:
  - "FilingJobState has .cancelled case now as Phase 6 forward-prep — model shape finalized here, mechanics in Phase 6"
  - "announce() defers to pendingAnnouncements when captureState == .recording; flushPendingAnnouncements() placed in beginTranscription() (not stopRecording()) to cover recordingDidTimeout() path"
  - "spawnFilingJob captures transcript/repo by value from parameters (not self.transcript) — Pitfall 1 prevention"
  - ".finished removed along with .filing (planner discretionary call per CONTEXT 'Claude's Discretion'); 3-case CaptureState: idle/recording/transcribing"
  - "testPushToTalkDuringFilingIsIgnored renamed to testPushToTalkDuringFilingIsAllowedUnderJobsModel — behavior inverted under D-09"
  - "testFilingErrorTokenAcquisitionSetsStatus and testParseFailedStatusMessageIsNotMisleading updated to jobs-model contract (Rule 1 auto-fix)"
metrics:
  duration: "549s (9m 9s)"
  completed: "2026-06-29"
  tasks_completed: 3
  files_changed: 5
---

# Phase 05 Plan 01: Concurrent Filing Jobs Model Summary

Refactored the serial filing pipeline into a concurrent per-job model. CaptureState loses `.filing` and `.finished`; capture returns to `.idle` the instant transcription completes; each filing runs as an independent `Task` tracked in `@Published var jobs: [FilingJob]`; outcomes are spoken through a defer-until-mic-idle announcement queue.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| TDD RED | FilingJob model tests | 6810eae | Tests/MakeAnIssueTests/FilingJobTests.swift |
| 1 | Create FilingJob model | 4f266df | Sources/MakeAnIssue/FilingJob.swift |
| TDD RED | Jobs model tests | faad684 | Tests/MakeAnIssueTests/AppStateTests.swift |
| 2 | Simplify CaptureState + jobs model + MenuView fix | 3ee9854 | AppState.swift, MenuView.swift |
| 3 | Rewrite four .filing-asserting tests | 9a29fec | Tests/MakeAnIssueTests/AppStateTests.swift |

## Outcome Verification

- `swift build`: clean (library + app target)
- `swift test`: 114 tests, 0 failures (107 baseline + 5 FilingJob model tests + 2 RED-phase jobs tests)
- `CaptureState` has exactly 3 cases: `.idle`, `.recording`, `.transcribing` — no `.filing`, no `.finished`
- `spawnFilingJob` count: 2 (declaration + call site in `beginTranscription`)
- `@Published var jobs: [FilingJob]` present; `func announce` present; `flushPendingAnnouncements` count: 2
- MenuView switches: exhaustive over 3-case enum only
- No `await MainActor.run {}` inside `spawnFilingJob` Task body (Pitfall 2)

## Deviations from Plan

### Auto-fixed Issues (Rule 1)

**1. [Rule 1 - Bug] testFilingErrorTokenAcquisitionSetsStatus — stale statusText contract**
- **Found during:** Task 3
- **Issue:** Test waited for `state.captureState == .idle` (immediately satisfied before filing completes under new model) then asserted `statusText` contains "github". Under the jobs model, `statusText` is never updated by filing errors; they're stored in `jobs[0].error` and spoken via `announce()`.
- **Fix:** Wait condition changed to `state.jobs.count == 1 && state.jobs[0].state == .failed`. Assertions updated to check `jobs[0].error == .tokenAcquisitionFailed` and spoken text is "issue filing failed" (D-04).
- **Files modified:** Tests/MakeAnIssueTests/AppStateTests.swift
- **Commit:** 9a29fec

**2. [Rule 1 - Bug] testParseFailedStatusMessageIsNotMisleading — stale statusText + speak contract**
- **Found during:** Task 3
- **Issue:** Test asserted `statusText == "Couldn't confirm..."` (no longer set by spawnFilingJob) and `speakCalled == false` (but `announce("issue filing failed")` now correctly calls onSpeak). The old `XCTAssertFalse(speakCalled)` checked for no false-success; in the new model the spoken text IS "issue filing failed" (failure, not false success).
- **Fix:** Updated to wait for `jobs[0].state == .failed`. Assertions check `jobs[0].error == .parseFailed`, spoken text is "issue filing failed", and spoken text does NOT contain "created" (preserving the no-false-success invariant via T-5-05).
- **Files modified:** Tests/MakeAnIssueTests/AppStateTests.swift
- **Commit:** 9a29fec

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `.finished` removed along with `.filing` | Planner's discretionary call (CONTEXT "Claude's Discretion"); `.finished` was transient/redundant once filing is decoupled from captureState. 3-case enum is cleaner. |
| `flushPendingAnnouncements()` in `beginTranscription()` not `stopRecording()` | Both key-up stop and `recordingDidTimeout()` call `beginTranscription()` directly — single flush point covers both paths without duplication. |
| `[weak self, id, transcript, repo]` capture list in spawnFilingJob Task | Pitfall 1: transcript/repo captured by value from parameters, never from self.transcript after await. Pitfall 4: weak self avoids retain cycle. |
| No `await MainActor.run {}` in spawnFilingJob Task | Task inherits @MainActor isolation from the calling @MainActor context (Pitfall 2). |
| testPushToTalkDuringFilingIsIgnored renamed | Behavior inverted under D-09 (PTT during filing is now ALLOWED). Renamed to testPushToTalkDuringFilingIsAllowedUnderJobsModel for clarity. |

## Known Stubs

None. All filing behavior is wired end-to-end; no placeholder data flows to UI rendering.

## Threat Surface Scan

No new security surface introduced beyond what the plan's threat model documents. `spawnFilingJob` captures `transcript`/`repo` by value (T-5-01 mitigation in place). `FilingJob` does not store the GitHub token (T-5-03). Retained terminal jobs hold transcripts in session memory only, no disk write (T-5-04 accepted).

## Self-Check: PASSED

Files exist:
- Sources/MakeAnIssue/FilingJob.swift ✓
- Sources/MakeAnIssue/AppState.swift ✓ (contains spawnFilingJob)
- Sources/MakeAnIssue/MenuView.swift ✓ (3-case switches)
- Tests/MakeAnIssueTests/FilingJobTests.swift ✓
- Tests/MakeAnIssueTests/AppStateTests.swift ✓ (rewritten tests)

Commits verified:
- 6810eae (test RED FilingJob)
- 4f266df (feat FilingJob)
- faad684 (test RED jobs model)
- 3ee9854 (feat AppState + MenuView)
- 9a29fec (feat test rewrites)
