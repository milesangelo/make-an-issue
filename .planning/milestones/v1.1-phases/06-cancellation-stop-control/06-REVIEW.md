---
phase: 06-cancellation-stop-control
reviewed: 2026-06-30T02:35:04Z
depth: standard
files_reviewed: 8
files_reviewed_list:
  - Sources/MakeAnIssue/AppDelegate.swift
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/CLIRunner.swift
  - Sources/MakeAnIssue/FilingJob.swift
  - Sources/MakeAnIssue/IssueFilingRunner.swift
  - Tests/MakeAnIssueTests/AppDelegateTests.swift
  - Tests/MakeAnIssueTests/AppStateTests.swift
  - Tests/MakeAnIssueTests/CLIRunnerTests.swift
findings:
  critical: 0
  warning: 6
  info: 4
  total: 10
status: issues_found
---

# Phase 6: Code Review Report

**Reviewed:** 2026-06-30T02:35:04Z
**Depth:** standard
**Files Reviewed:** 8
**Status:** issues_found

## Summary

Reviewed the Phase 6 cancellation / stop-control implementation: Swift task-cancellation
bridged to POSIX `kill(-pgid, …)` process-group signals (SIGTERM → SIGKILL), `cancel(jobID:)`
/ `cancelAll()` / `forceKillAllProcessTrees()` in `AppState`, and the quit-time teardown in
`AppDelegate.applicationShouldTerminate`.

The core safety invariants the prompt flagged are **correctly handled**:

- **pgid guards are sound everywhere.** Every `kill(-pid, …)` call site guards `> 0`
  (`forceKillAllProcessTrees` line 336, onCancel line 232, pre-launch SIGTERM line 183,
  timeout SIGTERM/SIGKILL lines 202/218). No path can reach `kill(-0, …)` (own group) or
  `kill(--1, …)` (every process). The empirical gate tests (A1/A2 in `CLIRunnerTests`) validate
  the child-is-its-own-group-leader assumption the whole design rests on.
- **Single-resume holds under the cancel/exit and timeout/exit races.** The lock-backed
  `RunState.claim()` makes resume an atomic check-then-act; `onCancel` signals only and never
  resumes; `terminationHandler` is the sole resume path on cancel. The 40-iteration stress tests
  exercise both boundaries.
- **The quit path always replies.** `defer { NSApp.reply(toApplicationShouldTerminate: true) }`
  sits above a `try?`-wrapped sleep and non-throwing teardown, so no exit path hangs.

No BLOCKER-level defect was proven. The findings below are robustness gaps and concurrency /
quality issues — most notably two SIGKILL-escalation paths that are inconsistent with each other
and a `nonisolated(unsafe)` cross-thread read of `pgid`.

## Warnings

### WR-01: `onCancel` SIGKILL escalation is unconditional — can signal a reused process group

**File:** `Sources/MakeAnIssue/CLIRunner.swift:239-242`
**Issue:** The detached escalation in `onCancel` sleeps 2s then unconditionally calls
`kill(-capturedPGID, SIGKILL)` with no liveness check:
```swift
Task.detached {
    try? await Task.sleep(for: .seconds(2))
    kill(-capturedPGID, SIGKILL)
}
```
The timeout path (lines 216-221) guards the identical SIGKILL with `if process.isRunning &&
process.processIdentifier > 0`, but `onCancel` does not. In the common case the SIGTERM has
already reaped the group well before 2s, so by the time this fires the original pid is gone. If
the OS has recycled that pid as a *new* process-group leader, this fires `SIGKILL` at an
**unrelated process group** (negative-pid = group-wide blast radius). PID reuse within 2s is
unlikely on macOS but not impossible under churn, and the inconsistency with the timeout path is
a latent footgun.
**Fix:** Mirror the timeout path — capture `process` and guard liveness before escalating:
```swift
Task.detached {
    try? await Task.sleep(for: .seconds(2))
    if process.isRunning {
        kill(-capturedPGID, SIGKILL)
    }
}
```

### WR-02: Pre-launch cancel sends SIGTERM with no SIGKILL escalation — process can linger to the 300s timeout

**File:** `Sources/MakeAnIssue/CLIRunner.swift:183-185`
**Issue:** When the enclosing Task is cancelled *before* `process.run()` completes, `onCancel`
fired with `pgid == 0` and took the early `return` (line 232) — so it scheduled **no** detached
SIGKILL escalation. The recovery code then sends a one-shot SIGTERM:
```swift
if Task.isCancelled && pgid > 0 {
    kill(-pgid, SIGTERM)
}
```
but also schedules no escalation. A child that ignores SIGTERM (e.g. a `docker run` wrapper
mid-exec) is therefore only reaped when the 300s timeout eventually fires. For a user-initiated
single `cancel(jobID:)` (not quit), the process keeps running for up to 300s after the user
asked to stop. The quit path masks this because `forceKillAllProcessTrees()` SIGKILLs at +2s, but
the non-quit cancel path has no backstop.
**Fix:** When taking the pre-launch SIGTERM branch, schedule the same bounded SIGKILL escalation
used in `onCancel`:
```swift
if Task.isCancelled && pgid > 0 {
    kill(-pgid, SIGTERM)
    let capturedPGID = pgid
    Task.detached {
        try? await Task.sleep(for: .seconds(2))
        if process.isRunning { kill(-capturedPGID, SIGKILL) }
    }
}
```

### WR-03: Data race on `pgid` between the run executor and the `onCancel` closure

**File:** `Sources/MakeAnIssue/CLIRunner.swift:131, 176, 231`
**Issue:** `pgid` is `nonisolated(unsafe) var pgid: pid_t = 0`. It is written on the task's
executor (`pgid = process.processIdentifier`, line 176) and read in `onCancel`
(`let capturedPGID = pgid`, line 231), which Swift may invoke synchronously from a *different*
thread the instant the task is cancelled. There is no lock, atomic, or happens-before edge on
`pgid` (unlike the lock-protected output `Data` in `RunState`). The "benign race" comment
(lines 126-130) is only true because an aligned 32-bit `pid_t` load/store does not tear on
arm64/x86_64 — i.e. correctness relies on an architecture-specific atomicity guarantee, not the
language memory model. ThreadSanitizer will flag this as a data race.
**Fix:** Promote `pgid` into the existing lock-backed `RunState` (a `setPGID`/`pgid()` pair under
the same `NSLock`), giving the cross-thread read a real happens-before edge and removing the
`nonisolated(unsafe)` escape hatch.

### WR-04: Race may report "filing cancelled" for an issue that was actually filed

**File:** `Sources/MakeAnIssue/IssueFilingRunner.swift:179` and `Sources/MakeAnIssue/AppState.swift:287-293`
**Issue:** After `await CLIRunner().run(...)` returns, `try Task.checkCancellation()` throws
`CancellationError` whenever the Task was cancelled — *including* the race where the AI CLI
completed successfully and the issue was created on GitHub microseconds before the SIGTERM
landed. In that case `run` returns `.success`, but `checkCancellation()` still throws, so the
job transitions to `.cancelled`, announces "filing cancelled", and discards the parsed
`IssueFilingResult`. The user is told the filing was cancelled while a real issue now exists on
GitHub. This is an inherent cancel-race, but here it is silent — there is no log of the
swallowed success.
**Fix:** When `run` returns `.success`, parse it and prefer reporting the real outcome even under
cancel, or at minimum `NSLog` the discarded issue URL before throwing so a stray-but-filed issue
is traceable. Document the chosen semantics in the cancel arm.

### WR-05: Quit always blocks the full 2s grace even when SIGTERM reaped the tree immediately

**File:** `Sources/MakeAnIssue/AppDelegate.swift:25-31`
**Issue:** `applicationShouldTerminate` unconditionally `try? await Task.sleep(for: .seconds(2))`
before replying, regardless of whether the in-flight processes have already died. A normal
`claude -p` SIGTERM is honored in well under a second, but every quit-with-active-job stalls a
fixed 2s before the app actually exits. There is no early-out that checks whether all jobs have
already left `.filing`.
**Fix:** Poll for completion inside the grace window and reply early, e.g. loop on
`appState.jobs.contains { $0.state == .filing }` with short sleeps up to a 2s cap, then
`forceKillAllProcessTrees()` only if survivors remain. Keeps the worst-case bound but removes the
guaranteed 2s quit stall.

### WR-06: Quit-teardown path (`terminateLater` + `forceKillAllProcessTrees`) has no test coverage

**File:** `Tests/MakeAnIssueTests/AppDelegateTests.swift:45-53` (and absent in `AppStateTests.swift`)
**Issue:** `AppDelegateTests` only covers the fast `.terminateNow` path
(`testTerminateNowWhenNoFilingJobs`) and the sweep filter. The actually-novel Phase 6 logic —
`applicationShouldTerminate` returning `.terminateLater`, `cancelAll()` driving SIGTERM, the 2s
grace, `forceKillAllProcessTrees()` issuing group SIGKILL, and the guaranteed `reply(...)` — has
no direct test. `AppState.forceKillAllProcessTrees()` is never invoked by any test, so its
`pgid > 0` guard and `.filing`-only filter are unverified at the unit level. The pgid mechanism
is well tested in `CLIRunnerTests`, but the AppState/AppDelegate quit wiring around it is not.
**Fix:** Add a test that injects a job with a known `processGroupID` (e.g. a real sleeping process
group captured via the `onSpawn`/seam path) and asserts `forceKillAllProcessTrees()` reaps it and
skips non-`.filing` jobs; add a test asserting the `.terminateLater` branch is taken and
`reply(toApplicationShouldTerminate:)` is reached when a `.filing` job exists.

## Info

### IN-01: `onSpawn` parameter is documented as "process group id" but delivers the PID

**File:** `Sources/MakeAnIssue/CLIRunner.swift:78-81, 176-177`
**Issue:** The `onSpawn` doc comment and `FilingJob.processGroupID` name say "process group id",
but the value passed is `process.processIdentifier` (the child PID). They are equal *only because*
the child is its own group leader (the A1 invariant). The naming hides that dependency and would
mislead anyone who later changes spawn semantics.
**Fix:** Either rename to reflect "child pid (== pgid, see A1 gate test)" or call `getpgid(pid)`
explicitly so the value is genuinely the pgid and the invariant is enforced rather than assumed.

### IN-02: `NSLog` of the full transcript leaks spoken user content to the system log

**File:** `Sources/MakeAnIssue/AppState.swift:230`
**Issue:** `NSLog("MakeAnIssue transcript: \(text)")` writes the user's full spoken transcript to
the unified system log on every successful transcription. This is pre-existing (not Phase 6), but
it is user-content/PII written to a shared, persistent sink.
**Fix:** Drop the transcript body from the log or gate it behind a debug-only flag; log a length
or hash instead.

### IN-03: Debug `NSLog` artifacts in `consumeLatestLaunchRequest`

**File:** `Sources/MakeAnIssue/AppDelegate.swift:52, 55, 58, 61`
**Issue:** Four `NSLog` lines (including `"...called!"`) read as development debug output rather
than intentional operational logging. Pre-existing, outside the Phase 6 change set, but worth
flagging for cleanup.
**Fix:** Demote to a debug-only logging path or remove.

### IN-04: Two independent SIGKILL escalations race on quit (redundant work)

**File:** `Sources/MakeAnIssue/AppDelegate.swift:24-29` and `Sources/MakeAnIssue/CLIRunner.swift:239-242`
**Issue:** On quit, `cancelAll()` triggers each job's `onCancel` detached SIGKILL-at-+2s, *and*
`AppDelegate` independently SIGKILLs survivors at +2s via `forceKillAllProcessTrees()`. Both fire
at roughly the same instant against the same group. Harmless (SIGKILL is idempotent), but the
duplicated timers obscure ownership of the teardown sequence and amplify the WR-01 reused-pgid
window by issuing the group SIGKILL twice.
**Fix:** Pick one owner of the force-kill on quit. Since `forceKillAllProcessTrees()` already
guards liveness via the `.filing` filter, consider that the canonical quit escalation and let the
non-quit `cancel(jobID:)` path own the per-job `onCancel` escalation.

---

_Reviewed: 2026-06-30T02:35:04Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
