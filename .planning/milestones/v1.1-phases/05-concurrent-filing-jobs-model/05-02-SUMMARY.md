---
phase: "05"
plan: "02"
subsystem: concurrent-filing-jobs-model
status: complete
tags: [concurrency, tests, jobs-model, swift, announcement, retention, SC-4]
dependency_graph:
  requires: [05-01]
  provides: [CONCUR-01 tests, CONCUR-02 tests, CONCUR-03 tests, D-06/D-07 retention tests, SC-4 verification]
  affects: [Tests/MakeAnIssueTests/AppStateTests.swift]
tech_stack:
  added: []
  patterns: [seam-injection-test, waitUntil-polling, concurrent-task-observation, deferred-announcement-assertion]
key_files:
  created: []
  modified:
    - Tests/MakeAnIssueTests/AppStateTests.swift
decisions:
  - "testTwoConcurrentFilingJobsCanBeSpawned uses 500ms stub sleep so both jobs remain .filing when jobs.count==2 is observed"
  - "testTwoConcurrentStubFilingsDoNotInterfere captures issue number before await so MainActor FIFO ordering gives distinct numbers to each job"
  - "testDeferredAnnouncementFlushedOnRecordingStop asserts !spokenTexts.isEmpty after stopRecording() because flushPendingAnnouncements() is synchronous in beginTranscription()"
  - "All 12 new tests added as additive methods only; no Sources/ file modified (test-only plan)"
metrics:
  duration: "845s (14m 5s)"
  completed: "2026-06-29"
  tasks_completed: 3
  files_changed: 1
---

# Phase 05 Plan 02: Concurrent Filing Jobs Model Tests Summary

Added 12 XCTest methods to AppStateTests.swift that lock the concurrency, announcement-deferral, retention, and SC-4 tempfile-isolation behaviors introduced by Plan 01. Full suite: 126 tests, 0 failures. No Sources/ file was modified.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | CONCUR-01 + CONCUR-02 + D-09 capture/concurrency tests | cac7ac1 | Tests/MakeAnIssueTests/AppStateTests.swift |
| 2 | CONCUR-02 distinct-transcript + CONCUR-03 announcement tests | a3418e6 | Tests/MakeAnIssueTests/AppStateTests.swift |
| 3 | D-06/D-07 retention tests + SC-4 tempfile-isolation verification | b0982d9 | Tests/MakeAnIssueTests/AppStateTests.swift |

## New Tests Added (12 total)

### Task 1 — CONCUR-01 / CONCUR-02 / D-09

| Test | Requirement | Assertion |
|------|-------------|-----------|
| testTranscriptionCompletionReturnsCaptureToIdleImmediately | CONCUR-01/SC-1 | captureState == .idle while jobs[0].state == .filing |
| testNewRecordingAllowedWhileFilingIsInFlight | D-09 | startRecording() reaches .recording while a job is .filing |
| testPTTReEntryDuringFilingStartsNewRecording | D-09 | onStartRecording called twice; PTT re-entry from .idle succeeds |
| testTwoConcurrentFilingJobsCanBeSpawned | CONCUR-02/SC-2 | jobs[0].state == .filing AND jobs[1].state == .filing simultaneously |

### Task 2 — CONCUR-02 distinct-transcript / CONCUR-03 announcements

| Test | Requirement | Assertion |
|------|-------------|-----------|
| testBothConcurrentJobsRetainDistinctTranscripts | CONCUR-02/Pitfall 1 | jobs[0].transcript != jobs[1].transcript; each matches the input |
| testSuccessfulFilingJobSpeaksIssueNumber | CONCUR-03/D-01 | spoken text contains "42" and "created" |
| testFailedFilingJobSpeaksGenericFailure | CONCUR-03/D-04/D-05 | spoken text == "issue filing failed" exactly |
| testAnnouncementDeferredDuringRecording | D-02 | onSpeak NOT called while captureState == .recording |
| testDeferredAnnouncementFlushedOnRecordingStop | D-03 | deferred text spoken after stopRecording() triggers flushPendingAnnouncements() |

### Task 3 — D-06/D-07 retention / SC-4

| Test | Requirement | Assertion |
|------|-------------|-----------|
| testCompletedFilingJobRetainedInJobsArray | D-06/D-07 | jobs.count == 1 && jobs[0].state == .done after success |
| testFailedFilingJobRetainedInJobsArray | D-06/D-07 | jobs.count == 1 && jobs[0].state == .failed after throw |
| testTwoConcurrentStubFilingsDoNotInterfere | SC-4 behavior | both jobs .done with distinct result.number (no cross-job bleed) |

## Outcome Verification

- `swift test --filter AppStateTests`: 50 tests, 0 failures (38 baseline + 12 new)
- `swift test` (full suite): 126 tests, 0 failures
- SC-4 source checks (all return 1):
  - `grep -c "static func file" Sources/MakeAnIssue/IssueFilingRunner.swift` → 1
  - `grep -c "make-an-issue-mcp-\\(UUID().uuidString)" Sources/MakeAnIssue/IssueFilingRunner.swift` → 1
  - `grep -c "defer { try? FileManager.default.removeItem" Sources/MakeAnIssue/IssueFilingRunner.swift` → 1
- `git diff --quiet -- Sources/` → clean (no Sources/ changes)

## Deviations from Plan

None — plan executed exactly as written. All 12 tests added as specified; SC-4 source file unmodified; no production code changed.

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| 500ms stub sleep for concurrent tests | Gives sufficient window to observe both jobs simultaneously .filing after the second job is spawned. A 200ms sleep risked the first job completing before jobs.count==2 was observed. |
| Per-invocation `myNumber` local capture for SC-4 test | `filingCallCount += 1; let myNumber = filingCallCount` executes before the await suspension point. MainActor FIFO ordering ensures Task 1 runs first (myNumber=1), then Task 2 (myNumber=2), giving distinct result.number per job. |
| `!spokenTexts.isEmpty` check immediately after `stopRecording()` in D-03 test | `flushPendingAnnouncements()` is called synchronously from `beginTranscription()`, so the deferred text enters the array synchronously. `waitUntil` is added as a safety guard for slow executor scheduling. |
| Defer/flush test split into two separate methods | `testAnnouncementDeferredDuringRecording` (D-02) and `testDeferredAnnouncementFlushedOnRecordingStop` (D-03) are independent, per the plan's five-test requirement. Each creates its own AppState instance. |

## Known Stubs

None — this plan is test-only (no production code). All tests wire real behavior through existing seams; no placeholder data.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. Test-only changes with no production surface.

## Self-Check: PASSED

Files exist:
- Tests/MakeAnIssueTests/AppStateTests.swift ✓ (50 test methods)

Commits verified:
- cac7ac1 (Task 1: CONCUR-01/02/D-09 tests)
- a3418e6 (Task 2: CONCUR-02 distinct-transcript + CONCUR-03 announcement tests)
- b0982d9 (Task 3: D-06/D-07 retention + SC-4 verification)

SC-4 source invariants confirmed:
- static func file: 1 ✓
- UUID tempfile: 1 ✓
- defer cleanup: 1 ✓
- IssueFilingRunner.swift unmodified ✓
