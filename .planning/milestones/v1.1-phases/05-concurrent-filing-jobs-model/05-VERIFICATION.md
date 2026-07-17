---
phase: 05-concurrent-filing-jobs-model
verified: 2026-06-29T15:05:00Z
status: passed
score: 7/7 must-haves verified
behavior_unverified: 0
overrides_applied: 0
re_verification: null
---

# Phase 05: Concurrent Filing Jobs Model Verification Report

**Phase Goal:** A developer can fire off issue filings back-to-back — capture returns to idle the moment transcription completes, and multiple filings run concurrently in the background, each announcing its own result.
**Verified:** 2026-06-29T15:05:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | After transcription completes, captureState == .idle immediately — a new recording can start before the prior filing finishes (CONCUR-01) | ✓ VERIFIED | AppState.swift line 229: `self.captureState = .idle` set before `spawnFilingJob(...)` is called. `testTranscriptionCompletionReturnsCaptureToIdleImmediately` asserts `captureState == .idle` while `jobs[0].state == .filing`; `testTwoConcurrentFilingJobsCanBeSpawned` reaffirms same. 126 tests, 0 failures. |
| 2 | Two or more filings can be in flight at once — jobs grows to N entries, each an independent Task (CONCUR-02) | ✓ VERIFIED | `spawnFilingJob` appends a new `FilingJob` then spawns an independent `Task` per call. `testTwoConcurrentFilingJobsCanBeSpawned` asserts `jobs[0].state == .filing` AND `jobs[1].state == .filing` simultaneously (500ms stubs). `testBothConcurrentJobsRetainDistinctTranscripts` asserts no transcript cross-bleed. |
| 3 | Each filing speaks its own "created issue #N" on success (D-01) and "issue filing failed" on any failure (D-04) (CONCUR-03) | ✓ VERIFIED | `announce("created issue #\(result.number)")` and `announce("issue filing failed")` in spawnFilingJob Task body. Tests: `testSuccessfulFilingJobSpeaksIssueNumber` (spoken text contains "42" and "created"); `testFailedFilingJobSpeaksGenericFailure` (spoken text == "issue filing failed"). |
| 4 | Announcements raised while captureState == .recording are deferred and flushed when recording stops (D-02/D-03) | ✓ VERIFIED | `announce()` appends to `pendingAnnouncements` when `captureState == .recording`; `flushPendingAnnouncements()` is called at the start of `beginTranscription()`. `testAnnouncementDeferredDuringRecording` asserts `onSpeak` not called while recording; `testDeferredAnnouncementFlushedOnRecordingStop` asserts deferred text is spoken after `stopRecording()`. |
| 5 | Terminal jobs (done / failed) are retained in jobs, not removed on completion (D-06/D-07) | ✓ VERIFIED | `spawnFilingJob` never removes entries from `jobs`; state is updated in-place. `testCompletedFilingJobRetainedInJobsArray` asserts `jobs.count == 1 && jobs[0].state == .done` after success; `testFailedFilingJobRetainedInJobsArray` asserts `.failed` retention. |
| 6 | Re-pressing PTT while a filing is in flight is allowed — the guard blocks only overlapping recordings (D-09) | ✓ VERIFIED | `startRecording()` guard is `captureState == .idle`; since `.filing` was removed from `CaptureState`, filing jobs never block PTT. `testNewRecordingAllowedWhileFilingIsInFlight` asserts `captureState == .recording` after `startRecording()` while `jobs[0].state == .filing`. |
| 7 | Per-invocation MCP tempfile isolation is preserved across concurrent jobs (SC-4 — verified-not-rebuilt in IssueFilingRunner.swift) | ✓ VERIFIED | `IssueFilingRunner.swift` is unchanged (`git diff --quiet` confirms). `static func file` present (1); UUID-named tempfile `make-an-issue-mcp-\(UUID().uuidString)` present (1); `defer { try? FileManager.default.removeItem` cleanup present (1). `testTwoConcurrentStubFilingsDoNotInterfere` asserts both concurrent jobs complete with distinct `result.number`. |

**Score:** 7/7 truths verified (0 present, behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/FilingJob.swift` | FilingJob struct + FilingJobState enum | ✓ VERIFIED | 37 lines; `struct FilingJob: Identifiable` with `id, transcript, repo, state, result, error, task`; `enum FilingJobState: Equatable` with 4 cases including `.cancelled` (Phase 6 forward-prep). Imported by AppState.swift. |
| `Sources/MakeAnIssue/AppState.swift` | jobs array, spawnFilingJob, announce/flush queue, 3-case CaptureState | ✓ VERIFIED | `CaptureState` has exactly 3 cases (grep -cE "case (filing\|finished)" = 0); `@Published var jobs: [FilingJob]` present; `spawnFilingJob` count = 2 (declaration + call site); `func announce` count = 1; `flushPendingAnnouncements` count = 2. |
| `Sources/MakeAnIssue/MenuView.swift` | CaptureState switches reduced to 3-case enum | ✓ VERIFIED | `StateBadge.label`, `StateBadge.backgroundColor`, and `ActionCard.body` switches each have exactly 3 arms: `.idle`, `.recording`, `.transcribing`. No `.filing` or `.finished` arms. |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | Four rewritten tests + 12 new concurrency/announcement tests | ✓ VERIFIED | `grep -c "captureState == .filing"` = 0 (old enum case gone). All 12 new test methods present: `testTranscriptionCompletionReturnsCaptureToIdleImmediately`, `testNewRecordingAllowedWhileFilingIsInFlight`, `testPTTReEntryDuringFilingStartsNewRecording`, `testTwoConcurrentFilingJobsCanBeSpawned`, `testBothConcurrentJobsRetainDistinctTranscripts`, `testSuccessfulFilingJobSpeaksIssueNumber`, `testFailedFilingJobSpeaksGenericFailure`, `testAnnouncementDeferredDuringRecording`, `testDeferredAnnouncementFlushedOnRecordingStop`, `testCompletedFilingJobRetainedInJobsArray`, `testFailedFilingJobRetainedInJobsArray`, `testTwoConcurrentStubFilingsDoNotInterfere`. |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | Unchanged (verify-not-rebuild) | ✓ VERIFIED | `git diff --quiet` confirms no changes. `static func file` = 1; UUID tempfile = 1; `defer` cleanup = 1. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AppState.swift` (beginTranscription success path) | `AppState.swift` (spawnFilingJob) | `captureState = .idle` then `spawnFilingJob(transcript: text, repo: repo)` | ✓ WIRED | AppState.swift lines 229–231: `.idle` set immediately before `spawnFilingJob` is called. Pattern `captureState = .idle` confirmed present; `spawnFilingJob` call site confirmed present. |
| `AppState.swift` (spawnFilingJob Task body) | `AppState.swift` (announce) | Job completion calls `announce(...)` which defers during .recording or routes to speakText/onSpeak | ✓ WIRED | `announce("created issue #\(result.number)")` at success; `announce("issue filing failed")` at both catch arms. `announce()` routes through `speakText()` → `onSpeak` seam when set, else real TTS. |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | `Sources/MakeAnIssue/AppState.swift` (spawnFilingJob/announce/jobs) | seam injection — `onRunIssueFiling` stubs hold jobs in-flight, `onSpeak` captures announcements | ✓ WIRED | All 12 new tests use `onRunIssueFiling` and/or `onSpeak` seam injection; `waitUntil { state.jobs... }` and `XCTAssert` on `state.jobs[i].state` confirm live wiring. |
| `Tests/MakeAnIssueTests/AppStateTests.swift` (SC-4 source check) | `Sources/MakeAnIssue/IssueFilingRunner.swift` (~lines 141–147) | verify-not-rebuild — static func + UUID tempfile + defer cleanup unchanged | ✓ WIRED | Source greps all return 1; `git diff --quiet` confirms file unmodified. `testTwoConcurrentStubFilingsDoNotInterfere` asserts distinct results across concurrent calls. |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full test suite — all 126 tests pass | `swift test 2>&1 \| tail -5` | `Executed 126 tests, with 0 failures (0 unexpected) in 4.205 seconds` | ✓ PASS |
| CaptureState has no .filing / .finished cases | `grep -cE "case (filing\|finished)" Sources/MakeAnIssue/AppState.swift` | 0 | ✓ PASS |
| spawnFilingJob declared and called | `grep -c "spawnFilingJob" Sources/MakeAnIssue/AppState.swift` | 2 | ✓ PASS |
| No MainActor.run inside spawnFilingJob Task body (Pitfall 2) | inspect grep output for lines 260–292 | only comment references at lines 259/268; actual `await MainActor.run` calls are in `beginTranscription`'s catch blocks, not in spawnFilingJob | ✓ PASS |
| IssueFilingRunner.swift unchanged (SC-4) | `git diff --quiet -- Sources/MakeAnIssue/IssueFilingRunner.swift` | exit 0 (UNCHANGED) | ✓ PASS |
| CONCUR-01 behavioral test present and named | `grep -c "testTranscriptionCompletionReturnsCaptureToIdleImmediately"` | 1 | ✓ PASS |
| CONCUR-02 behavioral test present and named | `grep -c "testTwoConcurrentFilingJobsCanBeSpawned"` | 1 | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CONCUR-01 | 05-01, 05-02 | After transcription, app returns to idle immediately so new recording can start without waiting | ✓ SATISFIED | `captureState = .idle` before `spawnFilingJob`; `testTranscriptionCompletionReturnsCaptureToIdleImmediately` passes; REQUIREMENTS.md marks Complete. |
| CONCUR-02 | 05-01, 05-02 | Multiple filings run concurrently in the background | ✓ SATISFIED | `spawnFilingJob` spawns independent Tasks into `jobs`; `testTwoConcurrentFilingJobsCanBeSpawned` and `testBothConcurrentJobsRetainDistinctTranscripts` pass; REQUIREMENTS.md marks Complete. |
| CONCUR-03 | 05-01, 05-02 | Each filing independently speaks its own "created issue #N" confirmation | ✓ SATISFIED | `announce()` called per-job with result-specific text; `testSuccessfulFilingJobSpeaksIssueNumber`, `testFailedFilingJobSpeaksGenericFailure`, `testAnnouncementDeferredDuringRecording`, `testDeferredAnnouncementFlushedOnRecordingStop` all pass; REQUIREMENTS.md marks Complete. |

No orphaned requirements: REQUIREMENTS.md maps only CONCUR-01/02/03 to Phase 5, and both PLAN files claim exactly those three IDs.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | No TBD/FIXME/XXX/TODO/HACK markers found in any phase-modified file. No stub return values, empty implementations, or placeholder data flows detected. |

### Human Verification Required

None. All must-haves are fully verified by code inspection and passing behavioral tests. No visual, real-time, or external-service checks required.

---

_Verified: 2026-06-29T15:05:00Z_
_Verifier: Claude (gsd-verifier)_
