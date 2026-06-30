---
status: testing
phase: 06-cancellation-stop-control
source: [06-VERIFICATION.md]
started: 2026-06-30T02:45:23Z
updated: 2026-06-30T02:45:23Z
---

## Current Test

number: 1
name: Confirm whether retaining cancelled jobs in jobs[] with state .cancelled satisfies ROADMAP SC-2 / REQUIREMENTS.md CANCEL-02 "removes the job"
expected: |
  Either the implementation (retain with .cancelled state, do NOT delete from jobs[]) is accepted as
  satisfying "removes the job" (interpreted as "removes from the in-flight/.filing set"), or
  SC-2/CANCEL-02 needs to be re-evaluated to require actual array deletion.
awaiting: user response

## Tests

### 1. CANCEL-02 / SC-2 — "removes the job" semantic decision
expected: Either the implementation (retain cancelled job in jobs[] with state .cancelled, do NOT delete) is accepted as satisfying "removes the job" — interpreted as "removes from the in-flight/.filing set" per plan D-02/D-03 — or SC-2/CANCEL-02 is re-evaluated to require actual array deletion. The spoken "filing cancelled" outcome and no-issue-filed conditions are already implemented and tested (testCancelJobIdTransitionsToCancel); only the retain-vs-delete semantic needs a human accept/reject call.
result: [pending]

### 2. CANCEL-03 / SC-3 — quit-mid-flight leaves no orphans (manual gate)
expected: Run the app, start a real filing, then quit mid-flight while the job is in .filing state. Within the 2s grace window, `pgrep -f claude` returns empty, `docker ps` shows no github-mcp-server container, and `ls $TMPDIR/make-an-issue-mcp-*.json` returns empty. The app quits cleanly (NSApp.reply fires; no hang). This exercises the .terminateLater path (cancelAll → 2s grace → forceKillAllProcessTrees → sweepMCPTempFiles → reply), which has no automated coverage (WR-06).
result: [pending]

## Summary

total: 2
passed: 0
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
