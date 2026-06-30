---
phase: 06-cancellation-stop-control
verified: 2026-06-29T20:45:00Z
status: human_needed
score: 2/4 must-haves verified
behavior_unverified: 1
overrides_applied: 0
behavior_unverified_items:
  - truth: "Quitting with in-flight filings calls cancelAll() (SIGTERM via bridge), waits 2s grace, force-kills survivors via forceKillAllProcessTrees() (SIGKILL), sweeps MCP tempfiles, and guarantees NSApp.reply — the .terminateLater path (SC-3 / CANCEL-03)"
    test: "Run the app, start a real filing, then quit mid-flight while the job is in .filing state; observe process state and tempfiles within 2s"
    expected: "cancelAll() sends group SIGTERM; after 2s grace forceKillAllProcessTrees() sends group SIGKILL to any survivor; sweepMCPTempFiles() removes make-an-issue-mcp-*.json; NSApp.reply(toApplicationShouldTerminate: true) fires; pgrep -f claude and docker ps return empty; no tempfile remains"
    why_human: "forceKillAllProcessTrees() is never invoked by any automated test. The entire .terminateLater branch of applicationShouldTerminate has no test. Only the fast path (.terminateNow) and the sweep filter have unit coverage. WR-06 from the code review explicitly flags this gap. Requires real docker+claude to exercise."
human_verification:
  - test: "Confirm whether retaining cancelled jobs in jobs[] with state .cancelled satisfies ROADMAP SC-2 / REQUIREMENTS.md CANCEL-02 'removes the job'"
    expected: "Either the implementation (retain with .cancelled state, do NOT delete from jobs[]) is accepted as satisfying 'removes the job' (interpreted as 'removes from the in-flight/.filing set'), or SC-2/CANCEL-02 needs to be re-evaluated to require actual array deletion"
    why_human: "ROADMAP SC-2 and REQUIREMENTS.md CANCEL-02 both say 'removes the job'. The implementation retains every cancelled job in jobs[] with state .cancelled (never deletes it). The plan (06-03-PLAN.md prohibitions) deliberately chose this: 'roadmap removes the job means removes from the in-flight/.filing set, not deletion' (D-02/D-03). The test testCancelledJobRetainedInJobsList asserts jobs.count == 1 (retained). This is a semantic deviation that requires a human accept/reject decision."
  - test: "Run the app, start a real filing, quit mid-flight; within the 2s grace verify pgrep -f claude, docker ps (no github-mcp-server container), and ls $TMPDIR/make-an-issue-mcp-*.json all return empty"
    expected: "No orphaned claude process, no leaked docker container, no leaked MCP tempfile after the 2s grace window"
    why_human: "The .terminateLater quit path (cancelAll + 2s grace + forceKillAllProcessTrees + sweep + NSApp.reply) has no automated test coverage. forceKillAllProcessTrees() is never invoked in any unit test. The manual gate from the plan is the required CANCEL-03 acceptance check for the in-flight-filings quit path."
---

# Phase 6: Cancellation / Stop Control — Verification Report

**Phase Goal:** Abort an in-flight filing by terminating its full `claude → docker` process tree; clean up on quit.
**Verified:** 2026-06-29T20:45:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC-1 | Stopping an in-flight filing terminates the full `claude → docker` process tree — no orphaned process, no leaked `--rm` container | VERIFIED | `kill(-pgid, SIGTERM/SIGKILL)` on both timeout and cancel paths. Positive-PID guards on every kill site. Empirical gate tests A1/A2 pass. `testCancelKillsProcessGroup` passes (process group reaped within 3s). |
| SC-2 | A cancelled filing surfaces "filing cancelled" (spoken + status), removes the job, and files no issue | UNCERTAIN | "filing cancelled" spoken and `result == nil` verified by `testCancelJobIdTransitionsToCancel`. BUT: ROADMAP/REQUIREMENTS say "removes the job" — code retains the job in `jobs[]` with `.cancelled` state (D-02/D-03 deliberate design decision). Needs human decision — see Human Verification #1. |
| SC-3 | Quitting with filings in flight terminates subprocesses and removes per-invocation MCP tempfiles, leaving no orphans | PRESENT_BEHAVIOR_UNVERIFIED | Fast path (.terminateNow + sweep on no-filing): VERIFIED by `testTerminateNowWhenNoFilingJobs` + `testSweepRemovesOnlyMCPTempFiles`. Slow path (.terminateLater + cancelAll + 2s grace + forceKill + sweep + reply): code is present and wired, but `forceKillAllProcessTrees()` is never invoked in any test and the .terminateLater branch has no automated coverage (WR-06). |
| SC-4 | Cancelling or quitting never triggers a double-resume crash or hung "Filing..." job | VERIFIED | `testCancelAndExitBoundaryResolvesExactlyOnce` survives 40 cancel/exit races without continuation-misuse trap. Source inspection confirms `onCancel` sends signals only (no `state.claim()`, no `continuation.resume`). `defer { NSApp.reply(...) }` guarantees quit reply. |

**Score:** 2/4 truths verified (1 uncertain, 1 present-but-behavior-unverified)

### CANCEL-02 Deviation Detail

ROADMAP SC-2 and REQUIREMENTS.md CANCEL-02 say "removes the job." The implementation retains the job in `jobs[]` with state `.cancelled`. This was a deliberate design decision documented in 06-03-PLAN.md prohibitions:

> "Never delete a cancelled job from jobs[] — it must be RETAINED with state .cancelled (D-02/D-03; roadmap 'removes the job' means removes from the in-flight/.filing set, not deletion)."

The test `testCancelledJobRetainedInJobsList` ASSERTS retention (count==1, state==.cancelled). This is intentional but diverges from the literal ROADMAP/REQUIREMENTS text. Human decision required.

To register this as an accepted deviation, add to this file's frontmatter:

```yaml
overrides:
  - must_have: "A cancelled filing surfaces a 'filing cancelled' outcome (spoken + status), removes the job, and files no issue"
    reason: "Plan D-02/D-03: retained with .cancelled state serves Phase 9 JOBS-01 job list UI. 'removes the job' interpreted as removes from in-flight/.filing set."
    accepted_by: "<your-name>"
    accepted_at: "<ISO timestamp>"
```

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/CLIRunner.swift` | withTaskCancellationHandler bridge + group kills + onSpawn | VERIFIED | `withTaskCancellationHandler` present (1 occurrence). `kill(-process.processIdentifier, SIGTERM/SIGKILL)` on timeout path (2 occurrences). `kill(-capturedPGID, SIGTERM/SIGKILL)` in onCancel. `capturedPGID > 0` guard (2 occurrences). `onSpawn` parameter wired (3 occurrences). |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | onProcessStarted parameter + try Task.checkCancellation() seam | VERIFIED | `onProcessStarted` parameter present and forwarded as `onSpawn` (2 occurrences). `try Task.checkCancellation()` between run() and switch result (1 occurrence). |
| `Sources/MakeAnIssue/FilingJob.swift` | `var processGroupID: pid_t?` field | VERIFIED | Field present with doc comment (1 occurrence). |
| `Sources/MakeAnIssue/AppState.swift` | cancel(jobID:), cancelAll(), forceKillAllProcessTrees(), CancellationError catch arm, onStarted pgid wiring | VERIFIED | All three methods present. `catch is CancellationError` arm precedes `IssueFilingError` arm. `announce("filing cancelled")` on cancel path. `processGroupID = pgid` in onStarted closure (1 occurrence). `kill(-pgid, SIGKILL)` with `pgid > 0` guard (1 occurrence). |
| `Sources/MakeAnIssue/AppDelegate.swift` | applicationShouldTerminate + sweepMCPTempFiles(in:) | VERIFIED | `applicationShouldTerminate` present. `appState.cancelAll()` called before Task.sleep. `forceKillAllProcessTrees()` called after. `defer { NSApp.reply(toApplicationShouldTerminate: true) }` present. `sweepMCPTempFiles` guards prefix + suffix. |
| `Tests/MakeAnIssueTests/CLIRunnerTests.swift` | Empirical gate tests + fleshed-out cancel tests | VERIFIED | `testSpawnedChildIsProcessGroupLeader` (A1/A2), `testNegativePIDSignalReapsProcessGroup`, `testCancelKillsProcessGroup`, `testCancelAndExitBoundaryResolvesExactlyOnce` — all present and passing. |
| `Tests/MakeAnIssueTests/AppStateTests.swift` | Four cancel tests fleshed out (not XCTSkip) | VERIFIED | `testCancelJobIdTransitionsToCancel`, `testCancelAnnouncementDeferredDuringRecording`, `testCancelAllCancelsEveryInFlightJob`, `testCancelledJobRetainedInJobsList` — all present, real assertions, no XCTSkip. |
| `Tests/MakeAnIssueTests/AppDelegateTests.swift` | Sweep isolation + fast-path terminateNow | VERIFIED | File exists. `testSweepRemovesOnlyMCPTempFiles` verifies prefix+suffix scoping. `testTerminateNowWhenNoFilingJobs` verifies fast path. 2/2 tests pass. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `CLIRunner.swift` (onCancel) | spawned process group (zsh → claude → docker) | `kill(-capturedPGID, SIGTERM)` + detached SIGKILL after 2s | WIRED | `capturedPGID > 0` guard present. `withTaskCancellationHandler` wraps `withCheckedContinuation`. `onCancel` sends signals only — no `state.claim()` or `continuation.resume`. |
| `IssueFilingRunner.swift` (file) | `CLIRunner.swift` (run onSpawn:) | `onSpawn: onProcessStarted` forwarded | WIRED | `grep -c onProcessStarted IssueFilingRunner.swift` = 2 (parameter + call). |
| `AppState.swift` (cancel/cancelAll) | `CLIRunner.swift` (withTaskCancellationHandler.onCancel) | `jobs[idx].task?.cancel()` → Task cancellation → CLIRunner onCancel | WIRED | `cancel(jobID:)` calls `jobs[idx].task?.cancel()` guarded by `state == .filing`. `cancelAll()` iterates `.filing` jobs. Both wired to stored Task handles. |
| `AppState.swift` (spawnFilingJob onProcessStarted) | `FilingJob.swift` (processGroupID) | `@Sendable` closure hops to `@MainActor`, sets `jobs[idx].processGroupID = pgid` | WIRED | `processGroupID = ` in AppState (1 occurrence). `Task { @MainActor in ... }` hop present. |
| `AppState.swift` (CancellationError catch) | `announce("filing cancelled")` | catch arm sets `.cancelled` state + calls announce() | WIRED | `catch is CancellationError` precedes `IssueFilingError` arm. `announce("filing cancelled")` present. |
| `AppDelegate.swift` (applicationShouldTerminate) | `AppState.swift` (cancelAll / forceKillAllProcessTrees) | `appState.cancelAll()` synchronously; teardown Task: 2s sleep → `appState.forceKillAllProcessTrees()` | WIRED (source-only; slow path untested) | Call ordering confirmed: cancelAll before sleep, forceKill after. But the slow path (.terminateLater branch) has no automated test. |
| `AppDelegate.swift` (teardown Task) | AppKit quit sequence | `defer { NSApp.reply(toApplicationShouldTerminate: true) }` inside teardown Task | WIRED (source-only) | `defer { NSApp.reply` grep = 1. Reply is inside the teardown Task body. |

### Data-Flow Trace (Level 4)

Phase 6 produces no new dynamic-data-rendering components. All new artifacts are process-control and signalling code. Level 4 data-flow trace is not applicable.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full test suite | `swift test` | 136 passed, 0 failures | PASS |
| A1/A2 empirical gate | `swift test --filter CLIRunnerTests.testSpawnedChildIsProcessGroupLeader` | 1 passed, 0 failures | PASS |
| Group SIGTERM reaps process group | `swift test --filter CLIRunnerTests.testCancelKillsProcessGroup` | 1 passed, 0 failures | PASS |
| Cancel/exit race (SC-4) | `swift test --filter CLIRunnerTests.testCancelAndExitBoundaryResolvesExactlyOnce` | 1 passed (40 iterations) | PASS |
| Cancel transitions job to .cancelled | `swift test --filter AppStateTests.testCancelJobIdTransitionsToCancel` | 1 passed | PASS |
| cancelAll() cancels all in-flight jobs | `swift test --filter AppStateTests.testCancelAllCancelsEveryInFlightJob` | 1 passed | PASS |
| Sweep prefix+suffix scoping | `swift test --filter AppDelegateTests.testSweepRemovesOnlyMCPTempFiles` | 1 passed | PASS |
| Fast-path terminateNow | `swift test --filter AppDelegateTests.testTerminateNowWhenNoFilingJobs` | 1 passed | PASS |

### Probe Execution

No probes declared in any PLAN. No `scripts/*/tests/probe-*.sh` found. Step skipped.

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|----------------|-------------|--------|----------|
| CANCEL-01 | 06-01, 06-02, 06-03 | User can stop an in-flight filing; terminates subprocess and full `claude → docker` process tree | SATISFIED | Group kill on timeout and cancel paths. Empirical gate tests A1/A2 confirm safety. `testCancelKillsProcessGroup` passes. |
| CANCEL-02 | 06-01, 06-02, 06-03 | Cancelled filing surfaces "filing cancelled" (spoken + status) and removes the job; no issue is filed | PARTIALLY SATISFIED | "filing cancelled" spoken and no issue filed: SATISFIED. "removes the job": UNCERTAIN — job is retained as .cancelled (see SC-2 deviation above). |
| CANCEL-03 | 06-01, 06-04 | Quitting with filings in flight cleans up subprocesses and per-invocation MCP tempfiles | PARTIALLY SATISFIED | Sweep prefix+suffix scoping and fast-path terminateNow: SATISFIED. Slow path (terminateLater + forceKillAllProcessTrees): PRESENT_BEHAVIOR_UNVERIFIED — no automated test. |

No orphaned requirements: REQUIREMENTS.md maps CANCEL-01/02/03 to Phase 6. All three appear in plan frontmatter. Coverage complete.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `CLIRunner.swift` | 239-242 | `onCancel` SIGKILL escalation is unconditional — no `process.isRunning` guard (WR-01) | WARNING | Unlike the timeout path which guards `if process.isRunning`, the onCancel detached SIGKILL fires unconditionally after 2s. If the OS recycled the PID within 2s, SIGKILL could signal an unrelated process group. Benign in practice (SIGKILL to non-existent group returns ESRCH), but inconsistent with the timeout path and a latent footgun under PID churn. |
| `CLIRunner.swift` | 183-185 | Pre-launch cancel sends SIGTERM with no SIGKILL escalation (WR-02) | WARNING | When cancel arrives before `process.run()` completes, the recovery code sends SIGTERM but does not schedule the bounded SIGKILL escalation. A process that ignores SIGTERM would survive until the 300s timeout fires. Non-quit cancel path has no backstop. |
| `IssueFilingRunner.swift` | 179 | `try Task.checkCancellation()` may discard a successfully-filed issue (WR-04) | INFO | If the AI CLI completes successfully microseconds before SIGTERM lands, `run()` returns `.success`, but `checkCancellation()` still throws, discarding the IssueFilingResult. User is told "filing cancelled" while a real GitHub issue exists. No log of the swallowed success URL. |
| `AppDelegate.swift` | 25-31 | `.terminateLater` path (cancelAll + grace + forceKill + sweep + reply) has no automated test (WR-06) | WARNING | `forceKillAllProcessTrees()` is never invoked in any test. Only the fast path and sweep filter have unit coverage. The behaviour-critical slow path is only verified by the manual gate. |
| `AppDelegate.swift` | 52-61 | Debug `NSLog` artifacts in `consumeLatestLaunchRequest` (IN-03, pre-existing) | INFO | Four NSLog lines including `"...called!"` are development debug output. Pre-existing, outside Phase 6 scope. |
| `AppState.swift` | 230 | `NSLog("MakeAnIssue transcript: \(text)")` leaks user transcript to system log (IN-02, pre-existing) | INFO | Writes full spoken transcript to the unified system log. Pre-existing, outside Phase 6 scope. |

No `TBD`, `FIXME`, or `XXX` markers found in any Phase 6-modified source file.

### Human Verification Required

#### 1. CANCEL-02 / SC-2 Semantic Deviation: "Removes the Job" vs. Retention

**Test:** Inspect the implemented behavior and confirm whether retaining a cancelled job in `jobs[]` with state `.cancelled` is an acceptable interpretation of CANCEL-02 and SC-2.

**Expected:** Either:
- (Accept) The plan's D-02/D-03 interpretation is accepted: "removes the job" means "removes from the in-flight/.filing set" (transitions to .cancelled, stays in array for Phase 9 JOBS-01 display). Add override to frontmatter.
- (Reject) CANCEL-02 requires actual deletion from `jobs[]`. A gap plan is needed to implement and test deletion.

**Why human:** The ROADMAP and REQUIREMENTS.md both say "removes the job." The implementation retains the job with `.cancelled` state, deliberately documented in 06-03-PLAN.md prohibitions. The test `testCancelledJobRetainedInJobsList` asserts and verifies this retention. No automated check can resolve whether this semantic deviation is acceptable.

---

#### 2. SC-3 Slow Path: Quit with In-Flight Filings (CANCEL-03 Manual Gate)

**Test:** With Docker Desktop and `claude` available: run the app, start a real filing, and quit mid-flight while the job is in `.filing` state. Within the 2s grace window, check:
- `pgrep -f claude` must return empty
- `docker ps` must show no `github-mcp-server` container
- `ls $TMPDIR/make-an-issue-mcp-*.json` must return no files

**Expected:** All three checks return empty within 3 seconds of quitting.

**Why human:** The `.terminateLater` branch of `applicationShouldTerminate` — the path that calls `appState.cancelAll()`, waits 2s, calls `appState.forceKillAllProcessTrees()`, then `sweepMCPTempFiles()` — has no automated test. `forceKillAllProcessTrees()` is never invoked in any unit test. The CLIRunner-level group SIGTERM is well-tested, but the AppDelegate-level orchestration of the full teardown sequence (cancelAll → grace → forceKill → sweep → reply) is only verifiable with a real claude + docker environment.

---

### Gaps Summary

No FAILED truths or MISSING/STUB artifacts. No BLOCKER defects.

Two items require human decision before the phase can be marked passed:

1. **CANCEL-02 semantic deviation** — The ROADMAP says "removes the job" but the implementation retains cancelled jobs in `jobs[]` with `.cancelled` state. This is a documented, intentional design decision (D-02/D-03) that the ROADMAP's literal text does not match. The developer must confirm whether the deviation is acceptable (add override) or requires a gap plan.

2. **SC-3 slow path behavior unverified** — The quit-with-in-flight-filings path (`applicationShouldTerminate` → `.terminateLater` → `cancelAll` + 2s grace → `forceKillAllProcessTrees` + sweep + reply) has no automated test coverage. `forceKillAllProcessTrees()` is never called in any test. The manual gate (pgrep + docker ps + tempfile check) from the plan must be run by the developer to confirm the full quit teardown sequence works end-to-end.

Code review warnings WR-01 (unconditional SIGKILL escalation in onCancel) and WR-02 (no SIGKILL escalation on pre-launch cancel path) are robustness gaps but do not block the phase goal — they represent edge cases where process cleanup could be incomplete under unlikely conditions (PID reuse within 2s, or a SIGTERM-ignoring docker wrapper mid-exec).

---

_Verified: 2026-06-29T20:45:00Z_
_Verifier: Claude (gsd-verifier)_
