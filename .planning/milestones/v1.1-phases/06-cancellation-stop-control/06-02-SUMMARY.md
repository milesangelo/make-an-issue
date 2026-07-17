---
phase: 06-cancellation-stop-control
plan: "02"
subsystem: cancellation
status: complete
tags: [process-groups, signals, cancellation, swift-concurrency, withTaskCancellationHandler]
dependency_graph:
  requires:
    - 06-01 (empirical A1/A2 gate — kill(-pgid) proven safe)
  provides:
    - process-group-kill-timeout-path
    - withTaskCancellationHandler-bridge
    - onSpawn-pgid-hook
    - IssueFilingRunner-checkCancellation-seam
    - FilingJob-processGroupID-field
  affects:
    - 06-03 (AppState cancel — uses onProcessStarted callback to store pgid on FilingJob)
    - 06-04 (AppDelegate quit-time — reads FilingJob.processGroupID for forceKillAllProcessTrees)
tech_stack:
  added: []
  patterns:
    - withTaskCancellationHandler bridge (Swift Concurrency stdlib)
    - POSIX process-group kill (kill(-pgid, sig)) — both SIGTERM and SIGKILL
    - RunState.claim() single-resume invariant preservation (SC-4)
    - Task.checkCancellation() seam in filing pipeline (CANCEL-02)
    - Callback chain (onSpawn → onProcessStarted) for pgid propagation
key_files:
  created: []
  modified:
    - Sources/MakeAnIssue/CLIRunner.swift
    - Sources/MakeAnIssue/IssueFilingRunner.swift
    - Sources/MakeAnIssue/FilingJob.swift
    - Tests/MakeAnIssueTests/CLIRunnerTests.swift
decisions:
  - "Process-group SIGTERM replaces process.terminate() on the timeout path: kill(-pid, SIGTERM) reaches zsh + claude + docker run, not only zsh (CANCEL-01 / Discretion Item 1)"
  - "onCancel sends signals ONLY — terminationHandler remains sole claim+resume path, preserving RunState.claim() single-resume invariant (SC-4 / T-6-04)"
  - "Pre-launch cancel race handled: after process.run() sets pgid, Task.isCancelled check fires SIGTERM synchronously so a cancelled task does not leave the process running (Pitfall 5)"
  - "nonisolated(unsafe) var pgid race (onCancel reads 0 before process.run writes it) is benign — guard capturedPGID > 0 skips the kill, and post-run isCancelled check covers the case (A5)"
  - "FilingJob.processGroupID: pid_t? added as additive field for 06-04 quit-time SIGKILL; set by AppState in 06-03 via onProcessStarted callback"
metrics:
  duration: "~11 minutes"
  completed: "2026-06-30"
  tasks_completed: 3
  files_modified: 4
requirements:
  - CANCEL-01
  - CANCEL-02
---

# Phase 06 Plan 02: Core Cancellation Mechanism Summary

**One-liner:** withTaskCancellationHandler bridges Task.cancel() → group SIGTERM (2s grace → SIGKILL) reaching the full zsh → claude → docker tree; IssueFilingRunner raises CancellationError; FilingJob carries the pgid handle.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Process-group kills on timeout escalation path | feef669 | CLIRunner.swift |
| 2 | withTaskCancellationHandler bridge + onSpawn hook + cancel tests | 626c5e0 | CLIRunner.swift, CLIRunnerTests.swift |
| 3 | IssueFilingRunner onProcessStarted + checkCancellation; FilingJob.processGroupID | cbbb59e | IssueFilingRunner.swift, FilingJob.swift |

## Verification Results

- `swift test --filter CLIRunnerTests` — 12 passed, 0 skipped, 0 failures
- `swift test` — 134 passed, 4 skipped (06-03 AppState scaffolds), 0 failures
- `grep -cE 'kill\(-process\.processIdentifier' CLIRunner.swift` — 2 (group SIGTERM + group SIGKILL on timeout path)
- `grep -cE 'process\.processIdentifier > 0' CLIRunner.swift` — 2 (positive-PID guards)
- `grep -c 'withTaskCancellationHandler' CLIRunner.swift` — 1
- `grep -c 'onSpawn' CLIRunner.swift` — 3 (parameter, call in operation, call in onCancel area)
- `grep -cE 'capturedPGID > 0' CLIRunner.swift` — 2 (onCancel guard)
- `grep -c 'try Task.checkCancellation' IssueFilingRunner.swift` — 1
- `grep -cE 'var processGroupID: pid_t\?' FilingJob.swift` — 1
- Source assertion: onCancel closure contains no `state.claim` and no `continuation.resume` — signals only

## New Behaviors

### CLIRunner.swift

- **Timeout path group kills (Task 1):** Both SIGTERM and SIGKILL escalation on the timeout path now target the process GROUP via negated identifier (`kill(-pid, sig)`). `process.processIdentifier > 0` guards prevent broadcasting to the caller's own group. SIGTERM-before-SIGKILL ordering and 2s grace unchanged.

- **withTaskCancellationHandler bridge (Task 2):** `withCheckedContinuation` is now wrapped in `withTaskCancellationHandler`. When the enclosing Task is cancelled:
  - `onCancel` captures the pgid, guards `> 0`, sends group SIGTERM immediately
  - `Task.detached` fires group SIGKILL after 2s grace
  - `onCancel` NEVER calls `state.claim()` or resumes the continuation — the `terminationHandler` (which fires as the signalled process exits) is the sole resume path (SC-4)
  - Pre-launch cancel race: after `process.run()` succeeds, `if Task.isCancelled { kill(-pgid, SIGTERM) }` covers the case where cancel arrived before pgid was written

- **onSpawn callback (Task 2):** New `onSpawn: (@Sendable (pid_t) -> Void)? = nil` parameter, called immediately after `process.run()` with the spawned process group id. All existing call sites pass nothing (source-compatible).

### IssueFilingRunner.swift (Task 3)

- New `onProcessStarted: (@Sendable (pid_t) -> Void)? = nil` parameter forwarded to `CLIRunner().run(onSpawn:)`. All existing call sites pass nothing (source-compatible).
- `try Task.checkCancellation()` inserted between `CLIRunner().run(...)` and `switch result` — a cancelled task throws `CancellationError` instead of misinterpreting the forced-exit result. The existing `defer { removeItem(tempURL) }` still runs on this throw path (no tempfile leak on cancel, CANCEL-02).

### FilingJob.swift (Task 3)

- `var processGroupID: pid_t?` added alongside the existing `task` field. Nil until AppState sets it via the `onProcessStarted` closure in 06-03. Read by `AppDelegate.forceKillAllProcessTrees()` in 06-04.

## Cancel Tests (CLIRunnerTests.swift)

Both scaffolds from 06-01 fleshed out:

- **testCancelKillsProcessGroup:** Spawns `sleep 30` with `onSpawn` capturing the pgid; cancels the Task; polls `kill(pgid,0) == ESRCH` within 3s. Proves the group is reaped via SIGTERM within the grace window.
- **testCancelAndExitBoundaryResolvesExactlyOnce:** 40-iteration loop: wraps `sleep 0.05` in a Task and cancels immediately (races natural exit). Survives without `SWIFT TASK CONTINUATION MISUSE` trap, proving `onCancel` never resumes the continuation (SC-4).

## Deviations from Plan

None — plan executed exactly as written.

- Added `import Darwin` to `CLIRunner.swift` for explicit POSIX signal symbol access (analogous to what was done for `CLIRunnerTests.swift` in 06-01; Darwin is transitively available but an explicit import is safer and not a new dependency).

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. All changes are internal to the subprocess signalling layer. The STRIDE threat register mitigations are confirmed present:

| Threat | Status |
|--------|--------|
| T-6-01 (wrong group — pgid ≤ 0) | Mitigated: `process.processIdentifier > 0` and `capturedPGID > 0` guards present on all kill sites |
| T-6-02 (SIGKILL before SIGTERM) | Mitigated: SIGTERM always first; SIGKILL only after 2s Task.sleep grace |
| T-6-04 (double-resume) | Mitigated: onCancel sends signals only; testCancelAndExitBoundaryResolvesExactlyOnce (40 iterations) passes |

## Self-Check: PASSED

- `Sources/MakeAnIssue/CLIRunner.swift` — exists ✓
- `Sources/MakeAnIssue/IssueFilingRunner.swift` — exists ✓
- `Sources/MakeAnIssue/FilingJob.swift` — exists ✓
- `Tests/MakeAnIssueTests/CLIRunnerTests.swift` — exists ✓
- Commits feef669, 626c5e0, cbbb59e — present in git log ✓
