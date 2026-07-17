---
phase: 06-cancellation-stop-control
audited_at: 2026-06-30
auditor: gsd-security-auditor (claude-sonnet-4-6)
asvs_level: standard
block_on: high
threats_total: 7
threats_open: 0
threats_closed: 7
result: SECURED
---

# Security Audit — Phase 6: Cancellation / Stop Control

## Summary

**Phase:** 06 — cancellation-stop-control
**Threats Closed:** 7/7
**ASVS Level:** Standard (block_on: high)
**Result:** SECURED

All declared mitigations are present in the implemented code. No open threats. No unregistered
threat flags from any SUMMARY.md.

---

## Threat Verification

| Threat ID | Category | Disposition | Status | Evidence |
|-----------|----------|-------------|--------|----------|
| T-6-01 | Tampering (wrong process group) | mitigate | CLOSED | See detail below |
| T-6-02 | Elevation of Privilege (docker --rm leak) | mitigate | CLOSED | See detail below |
| T-6-03 | Denial of Service (app hangs in Quit) | mitigate | CLOSED | See detail below |
| T-6-04 | Denial of Service (double-resume crash) | mitigate | CLOSED | See detail below |
| T-6-05 | Spoofing (false "created issue #N") | mitigate | CLOSED | See detail below |
| T-6-06 | Tampering / data loss (broad tempfile sweep) | mitigate | CLOSED | See detail below |
| T-6-SC | Tampering (supply chain) | accept | CLOSED | Phase 6 installs zero packages |

---

## Per-Threat Evidence

### T-6-01 — Tampering: group signal sent to wrong process group (pgid ≤ 0 → caller's own group)

**Declared mitigation:** Guard `pgid > 0` / `process.processIdentifier > 0` / `capturedPGID > 0`
before any `kill(-pgid, …)` on all kill sites.

**Verified kill sites and their guards:**

| File | Line | Guard | Kill |
|------|------|-------|------|
| CLIRunner.swift | 183–184 | `if Task.isCancelled && pgid > 0` | `kill(-pgid, SIGTERM)` (pre-launch race) |
| CLIRunner.swift | 202–203 | `if process.processIdentifier > 0` | `kill(-process.processIdentifier, SIGTERM)` (timeout) |
| CLIRunner.swift | 218–219 | `if process.isRunning && process.processIdentifier > 0` | `kill(-process.processIdentifier, SIGKILL)` (timeout escalation) |
| CLIRunner.swift | 232, 235 | `guard capturedPGID > 0 else { return }` | `kill(-capturedPGID, SIGTERM)` (onCancel) |
| CLIRunner.swift | 241 | `capturedPGID > 0` enforced at entry (line 232) | `kill(-capturedPGID, SIGKILL)` (onCancel escalation, Task.detached) |
| AppState.swift | 336–337 | `if let pgid = job.processGroupID, pgid > 0` | `kill(-pgid, SIGKILL)` (forceKillAllProcessTrees) |

Every negated-identifier kill site is guarded. No unguarded `kill(-…)` call found in any
Phase 6-modified file.

---

### T-6-02 — Elevation of Privilege: SIGKILL before SIGTERM leaks persistent docker --rm container

**Declared mitigation:** SIGTERM sent first; SIGKILL only after a bounded 2s grace; `docker run`
receives SIGTERM time to stop + auto-remove its `--rm` container.

**Verified ordering on all three kill paths:**

**Timeout path (CLIRunner.swift:202–221):**
- Line 202–203: `kill(-process.processIdentifier, SIGTERM)` — first
- Lines 216–219: `Task { try? await Task.sleep(for: .seconds(2)); if process.isRunning … kill(-process.processIdentifier, SIGKILL) }` — after 2s grace

**onCancel path (CLIRunner.swift:225–243):**
- Line 235: `kill(-capturedPGID, SIGTERM)` — first
- Lines 239–241: `Task.detached { try? await Task.sleep(for: .seconds(2)); kill(-capturedPGID, SIGKILL) }` — after 2s grace

**Quit path (AppDelegate.swift:19–35):**
- Line 24: `appState.cancelAll()` — synchronous before any sleep; propagates Swift Task.cancel()
  → CLIRunner onCancel → group SIGTERM
- Lines 31–32: `try? await Task.sleep(for: .seconds(2)); appState.forceKillAllProcessTrees()` —
  SIGKILL only after 2s async grace

Confirmed: SIGTERM always precedes SIGKILL with a 2-second bounded grace on every path.

**UAT fix (commit 30fd152) reflected:** `Self.sweepMCPTempFiles()` is called synchronously at
AppDelegate.swift:28, before `return .terminateLater`, resolving a race on MenuBarExtra quit where
the async teardown Task could be reaped before completing the sweep.

---

### T-6-03 — Denial of Service: applicationShouldTerminate returns .terminateLater without replying

**Declared mitigation:** `defer { NSApp.reply(toApplicationShouldTerminate: true) }` inside the
teardown Task; `sweepMCPTempFiles` never throws (`try?`).

**Verified:**
- AppDelegate.swift:30: `defer { NSApp.reply(toApplicationShouldTerminate: true) }` — present
  inside the `Task { @MainActor in … }` body; fires on every exit path including unexpected errors.
- AppDelegate.swift:44: `guard let contents = try? FileManager.default.contentsOfDirectory(…)` —
  never throws past the guard.
- AppDelegate.swift:51: `try? FileManager.default.removeItem(at:)` — never throws.
- The `Task.sleep` at line 31 uses `try?` so cancellation of the teardown Task cannot bypass the
  `defer` block.

The fast path at AppDelegate.swift:21–22 returns `.terminateNow` directly — no reply needed there.

---

### T-6-04 — Denial of Service: hung ".filing" job / double-resume continuation crash

**Declared mitigation:** `onCancel` sends signals only (no `state.claim()`, no
`continuation.resume`); `RunState.claim()` under NSLock is the sole resume path.

**Verified — onCancel closure body (CLIRunner.swift:225–243):**
```
let capturedPGID = pgid
guard capturedPGID > 0 else { return }
kill(-capturedPGID, SIGTERM)
Task.detached {
    try? await Task.sleep(for: .seconds(2))
    kill(-capturedPGID, SIGKILL)
}
```
No call to `state.claim()` or `continuation.resume` inside the onCancel closure.
The grep for `state.claim` and `continuation.resume` in CLIRunner.swift returns hits only in the
`terminationHandler` (line 152, 155, 158), spawn-failure path (lines 169–170), and timeout Task
(lines 195, 207) — all outside the onCancel closure.

**AppState.swift:318–321 (cancel(jobID:)):** calls only `jobs[idx].task?.cancel()` — the `.cancelled`
state transition is in the CancellationError catch arm (AppState.swift:287–293), not in
`cancel(jobID:)` itself, preventing a premature state update before the process is confirmed dead.

---

### T-6-05 — Spoofing: cancelled job announces false "created issue #N"

**Declared mitigation:** Cancelled job speaks exactly "filing cancelled" and sets `result == nil`.

**Verified (AppState.swift:287–293):**
```swift
} catch is CancellationError {
    if let idx = self.jobs.firstIndex(where: { $0.id == id }) {
        self.jobs[idx].state = .cancelled   // retain in jobs[], do NOT remove (D-02/D-03)
    }
    self.announce("filing cancelled")   // D-05
}
```
- `self.jobs[idx].result` is not assigned in this arm → `result` remains `nil`.
- `self.announce("created issue #\(result.number)")` (AppState.swift:286) is only reachable in the
  `do { … }` success block — unreachable when CancellationError is thrown.
- CancellationError arm precedes `catch let filingError as IssueFilingError` arm (AppState.swift:294),
  so CancellationError cannot fall through to the failure path either.

---

### T-6-06 — Tampering / data loss: overly broad tempfile sweep deletes unrelated files

**Declared mitigation:** Delete only files matching BOTH prefix `make-an-issue-mcp-` AND suffix
`.json`.

**Verified (AppDelegate.swift:48–51):**
```swift
for url in contents
    where url.lastPathComponent.hasPrefix("make-an-issue-mcp-")
       && url.lastPathComponent.hasSuffix(".json") {
    try? FileManager.default.removeItem(at: url)
}
```
Both conditions are required (`&&`). Files matching only the prefix or only the suffix survive the
sweep. This is tested by `testSweepRemovesOnlyMCPTempFiles` in AppDelegateTests.swift, which
confirms that `make-an-issue-mcp-keep` (wrong suffix) and `unrelated-<uuid>.json` (wrong prefix)
are both retained after a sweep.

---

### T-6-SC — Tampering (supply chain): npm/pip/cargo installs

**Disposition:** accept (N/A)

Phase 6 installs zero packages. No `package.json`, `requirements.txt`, `Cargo.toml`, or equivalent
dependency manifests were added or modified by any Phase 6 plan. No install/slopcheck checkpoint
required. Verified by inspection of the four PLAN.md files — all changes are confined to Swift
source and test files.

---

## Unregistered Threat Flags

**None.** All four SUMMARY.md files (06-01 through 06-04) reported no new threat surface:
no new network endpoints, auth paths, file access patterns, or schema changes were introduced.

---

## Known Observations (Non-Blocking)

The following items were flagged by the code reviewer (WR-xx) and are documented in
06-VERIFICATION.md. They are not in the Phase 6 threat register and are informational only:

- **WR-01** (CLIRunner.swift:239–242): The onCancel SIGKILL escalation fires unconditionally after
  2s with no `process.isRunning` guard, unlike the timeout path. If the OS recycled the PID within
  2s, SIGKILL could signal an unrelated process group. Benign in practice (ESRCH returned), but
  inconsistent with the timeout path.
- **WR-02** (CLIRunner.swift:183–184): The pre-launch cancel race sends SIGTERM but schedules no
  SIGKILL escalation. A SIGTERM-ignoring process on this path has no force-kill backstop.
- **WR-06** (AppDelegate.swift:25–31): The `.terminateLater` slow path (cancelAll + 2s grace +
  forceKillAllProcessTrees + sweep + reply) has no automated unit-test coverage.
  `forceKillAllProcessTrees()` is never invoked by any test. Manual gate required (CANCEL-03).

These do not constitute open threats in the T-6-xx register. They may be addressed in a future
hardening pass.

---

## Audit Scope

Files verified:
- `Sources/MakeAnIssue/CLIRunner.swift`
- `Sources/MakeAnIssue/AppState.swift`
- `Sources/MakeAnIssue/AppDelegate.swift`
- `Sources/MakeAnIssue/IssueFilingRunner.swift`
- `Sources/MakeAnIssue/FilingJob.swift`
- `.planning/phases/06-cancellation-stop-control/06-01-PLAN.md` through `06-04-PLAN.md`
- `.planning/phases/06-cancellation-stop-control/06-01-SUMMARY.md` through `06-04-SUMMARY.md`
- `.planning/phases/06-cancellation-stop-control/06-VERIFICATION.md`
