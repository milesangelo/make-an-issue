---
phase: 06-cancellation-stop-control
plan: "03"
subsystem: cancellation
status: complete
tags: [cancellation, jobs-model, swift-concurrency, CancellationError, process-groups, AppState]
dependency_graph:
  requires:
    - 06-02 (onProcessStarted callback, FilingJob.processGroupID, IssueFilingRunner checkCancellation seam)
  provides:
    - cancel(jobID:)-AppState-method
    - cancelAll()-AppState-method
    - forceKillAllProcessTrees()-AppState-method
    - CancellationError-catch-arm-in-spawnFilingJob
    - onRunIssueFiling-3arg-seam
    - pgid-wiring-in-spawnFilingJob
  affects:
    - 06-04 (AppDelegate quit-time — calls cancelAll() + forceKillAllProcessTrees())
tech_stack:
  added: []
  patterns:
    - CancellationError catch arm ordering (before IssueFilingError — not a subtype)
    - @Sendable hop-to-MainActor pattern for callback wiring across concurrency domains
    - POSIX group SIGKILL with pgid > 0 positive guard (T-6-01)
    - defer-until-mic-idle announce() pattern extended to cancel path (D-05)
    - Task.sleep CancellationError as unit-test cancel stub
key_files:
  created: []
  modified:
    - Sources/MakeAnIssue/AppState.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift
decisions:
  - "onRunIssueFiling seam gains a @escaping @Sendable (pid_t) -> Void 3rd parameter — @escaping required on inner closure type so the default closure body can forward it to IssueFilingRunner.file(onProcessStarted:) without a non-escaping diagnostic"
  - "CancellationError catch arm placed before IssueFilingError arm (CancellationError is not an IssueFilingError; the generic catch would have swallowed it as a failure)"
  - "cancel(jobID:) only calls task?.cancel() — state transition to .cancelled is owned solely by the CancellationError catch arm (avoids premature state update before the process is dead)"
  - "Four cancel tests use Task.sleep(for: .seconds(60)) as the filing stub — Task.sleep throws CancellationError on cancel; no real subprocess needed at the jobs-model unit layer"
metrics:
  duration: "~18 minutes"
  completed: "2026-06-30"
  tasks_completed: 3
  files_modified: 2
requirements:
  - CANCEL-01
  - CANCEL-02
---

# Phase 06 Plan 03: AppState Cancel Surface Summary

**One-liner:** AppState cancel surface wires Task.cancel() → CancellationError catch arm → .cancelled state + "filing cancelled" TTS, with cancelAll() + forceKillAllProcessTrees() as quit-path APIs; four cancel tests validate the full contract.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | AppState cancel surface — seam rewire, pgid wiring, CancellationError catch, cancel/cancelAll/forceKill | ebb4401 | AppState.swift |
| 2 | Update existing AppStateTests onRunIssueFiling call sites to new 3-arg seam arity | b38847d | AppStateTests.swift |
| 3 | Flesh out the four cancel tests (state, announcement, cancelAll, retention) | d1c9030 | AppStateTests.swift |

## Verification Results

- `swift build` — green after Task 1 (library + app; test target fixed in Task 2)
- `swift test` after Task 2 — 134 passed, 4 skipped (cancel scaffolds), 0 failures
- `swift test` after Task 3 — 134 passed, 0 skipped, 0 failures
- `grep -c 'func cancel(jobID:' AppState.swift` — 1
- `grep -c 'func cancelAll' AppState.swift` — 1
- `grep -c 'func forceKillAllProcessTrees' AppState.swift` — 1
- `grep -c 'catch is CancellationError' AppState.swift` — 1
- `grep -c 'announce("filing cancelled")' AppState.swift` — 1
- `grep -cE 'kill\(-pgid, SIGKILL\)' AppState.swift` — 1
- `grep -cE 'pgid > 0' AppState.swift` — 2 (forceKill guard + catch arm context)
- `grep -c 'processGroupID = ' AppState.swift` — 1 (pgid wiring in spawnFilingJob)
- `swift test --filter AppStateTests 2>&1 | grep -i skip` — only `testNoRepoBoundSkipsFilingAndReturnsToIdle` (test name, not XCTSkip)

## New Behaviors

### AppState.swift

**onRunIssueFiling seam extended (Task 1):**
The seam type gains a trailing `@escaping @Sendable (pid_t) -> Void` parameter. The `@escaping` annotation is required so the default closure body can forward the callback to `IssueFilingRunner.file(onProcessStarted:)` without a non-escaping diagnostic. The default closure now passes `onStarted` through.

**pgid wiring (Task 1):**
`spawnFilingJob` builds a `@Sendable` `onStarted` closure that captures `[weak self, id]`. When CLIRunner fires the callback (on a non-main executor), the closure creates a `Task { @MainActor in ... }` to hop to the main actor before mutating `jobs[idx].processGroupID = pgid`. This stores the process group id for `forceKillAllProcessTrees()` without a data race.

**CancellationError catch arm (Task 1):**
Placed BEFORE the `catch let filingError as IssueFilingError` arm (ordering is critical — `CancellationError` is not an `IssueFilingError`). On cancel:
- Sets `jobs[idx].state = .cancelled` (retains the job in `jobs[]` — does NOT remove it, D-02/D-03)
- Calls `announce("filing cancelled")` (defers if `captureState == .recording`, D-05)
- Sets no `result` or `error` — no issue was filed

**cancel(jobID:) (Task 1):**
Guards `state == .filing` before calling `jobs[idx].task?.cancel()`. No-ops for terminal/non-filing jobs. Does not set `.cancelled` itself — that transition is the catch arm's responsibility.

**cancelAll() (Task 1):**
Iterates `jobs where state == .filing` and calls `job.task?.cancel()` on each. `Task` is a reference type so cancelling via a value copy of `FilingJob` still cancels the actual Task.

**forceKillAllProcessTrees() (Task 1):**
Iterates `jobs where state == .filing`; guards `if let pgid = job.processGroupID, pgid > 0` (T-6-01) before `kill(-pgid, SIGKILL)`. The negative pid targets the process group (zsh → claude → docker tree), not a single PID.

### AppStateTests.swift

**Arity sweep (Task 2):**
All 24 `{ _, _ in ... }` stubs updated to `{ _, _, _ in ... }`. The one named-parameter stub `{ transcript, repo in ... }` updated to `{ transcript, repo, _ in ... }`. Purely mechanical — no assertion text changed.

**Four cancel tests (Task 3):**

- **testCancelJobIdTransitionsToCancel:** Sleeping stub (60s) + `cancel(jobID:)` → `.cancelled`, spoken "filing cancelled", `result == nil`. Confirms CANCEL-01 (trigger) and CANCEL-02 (outcome).

- **testCancelAnnouncementDeferredDuringRecording:** First job sleeping, second recording active → cancel fires, `announce("filing cancelled")` defers (D-02). After `stopRecording()`, `flushPendingAnnouncements()` speaks it (D-03).

- **testCancelAllCancelsEveryInFlightJob:** Two concurrent sleeping jobs. `cancelAll()` → both reach `.cancelled`. Confirms the quit-path API covers N concurrent jobs.

- **testCancelledJobRetainedInJobsList:** `jobs.count == 1`, `jobs[0].state == .cancelled` after cancel. Confirms D-02/D-03 retention (not deletion from `jobs[]`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] @escaping required on inner closure parameter in seam type**
- **Found during:** Task 1 (swift build error)
- **Issue:** `onRunIssueFiling: @escaping (String, RepoBinding, @Sendable (pid_t) -> Void)` — the inner `@Sendable (pid_t) -> Void` parameter is implicitly non-escaping in the default closure body, causing a Swift diagnostic when passing `onStarted` to `IssueFilingRunner.file(onProcessStarted:)` which expects an `@escaping` closure.
- **Fix:** Changed to `@escaping @Sendable (pid_t) -> Void` on both the stored property type and the init parameter. Swift allows `@escaping` on closure parameters within function types stored in init parameters.
- **Files modified:** `Sources/MakeAnIssue/AppState.swift`
- **Commit:** ebb4401 (same task commit)

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. All changes are internal to AppState job-model wiring. The STRIDE threat register mitigations are confirmed present:

| Threat | Status |
|--------|--------|
| T-6-01 (wrong group — pgid ≤ 0) | Mitigated: `if let pgid = job.processGroupID, pgid > 0` guard on `kill(-pgid, SIGKILL)` in `forceKillAllProcessTrees()` |
| T-6-04 (hung .filing job / double-resume) | Mitigated: `testCancelJobIdTransitionsToCancel` reaches `.cancelled` (no hang); catch arm transitions state exactly once |
| T-6-05 (false outcome — cancelled speaks "created #N") | Mitigated: `testCancelJobIdTransitionsToCancel` asserts `spokenTexts.first == "filing cancelled"` and `result == nil` |

## Self-Check: PASSED

- `Sources/MakeAnIssue/AppState.swift` — exists ✓
- `Tests/MakeAnIssueTests/AppStateTests.swift` — exists ✓
- Commits ebb4401, b38847d, d1c9030 — present in git log ✓
- `swift test` — 134 passed, 0 skipped, 0 failures ✓
