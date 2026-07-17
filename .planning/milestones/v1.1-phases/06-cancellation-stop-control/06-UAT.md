---
status: complete
phase: 06-cancellation-stop-control
source: [06-VERIFICATION.md]
started: 2026-06-30T02:45:23Z
updated: 2026-06-30T03:52:00Z
---

## Current Test

[testing complete]

## Tests

### 1. CANCEL-02 / SC-2 — "removes the job" semantic decision
expected: Either the implementation (retain cancelled job in jobs[] with state .cancelled, do NOT delete) is accepted as satisfying "removes the job" — interpreted as "removes from the in-flight/.filing set" per plan D-02/D-03 — or SC-2/CANCEL-02 is re-evaluated to require actual array deletion. The spoken "filing cancelled" outcome and no-issue-filed conditions are already implemented and tested (testCancelJobIdTransitionsToCancel); only the retain-vs-delete semantic needs a human accept/reject call.
result: pass
reported: "Lets leave it in the jobs array in cancelled — retain with .cancelled state accepted as satisfying 'removes the job'."

### 2. CANCEL-03 / SC-3 — quit-mid-flight leaves no orphans (manual gate)
expected: Run the app, start a real filing, then quit mid-flight while the job is in .filing state. Within the 2s grace window, `pgrep -f claude` returns empty, `docker ps` shows no github-mcp-server container, and `ls $TMPDIR/make-an-issue-mcp-*.json` returns empty. The app quits cleanly (NSApp.reply fires; no hang). This exercises the .terminateLater path (cancelAll → 2s grace → forceKillAllProcessTrees → sweepMCPTempFiles → reply), which has no automated coverage (WR-06).
result: issue
reported: "Quit while filing was in flight. claude subprocess (15665) gone and no github-mcp-server container — but a leftover MCP temp config file (make-an-issue-mcp-738D2182-...json, github docker launcher) remained in $TMPDIR after the app exited. sweepMCPTempFiles did not remove it on the .terminateLater quit path."
severity: major
resolution: fixed
fix_commit: 30fd152
fix_note: "Added synchronous Self.sweepMCPTempFiles() in applicationShouldTerminate before returning .terminateLater (AppDelegate.swift). Regression test testTerminateLaterSweepsMCPTempFileSynchronously verified red without fix, green with it; full suite 137 passing. Manual quit-mid-flight gate WAIVED by user decision (2026-06-30), accepted on the deterministic unit-test proof. Original wording: re-run the manual ⌘Q-mid-flight gate to confirm in the real app."

## Summary

total: 2
passed: 1
issues: 1
pending: 0
skipped: 0
blocked: 0

## Gaps

- truth: "Quitting the app mid-flight (job in .filing state) leaves no orphaned MCP temp config files in $TMPDIR"
  status: failed
  reason: "User reported: quit while filing in flight; claude subprocess and docker container were cleaned up, but a leftover make-an-issue-mcp-*.json temp config file remained in $TMPDIR after the app exited. sweepMCPTempFiles did not remove it on the .terminateLater quit path."
  severity: major
  test: 2
  root_cause: "Confirmed via user: ⌘Q with a job actively in .filing state, so applicationShouldTerminate's slow path ran (cancelAll → .terminateLater → 2s grace → forceKillAllProcessTrees → sweepMCPTempFiles). Processes/container were cleaned (SIGTERM from cancelAll), but the MCP temp file survived. All cleanup is hung off an unstructured `Task { @MainActor in ... }` (AppDelegate.swift:25-30); sweepMCPTempFiles() is the LAST statement, after a 2s Task.sleep. During MenuBarExtra ⌘Q termination the process is reaped before that async Task resumes/completes its sweep — a timing race the unit test never exercises (it calls sweepMCPTempFiles(in:) directly, bypassing the quit Task). IssueFilingRunner's own `defer { removeItem }` (line 150) also did not win the race before teardown."
  artifacts:
    - path: "Sources/MakeAnIssue/AppDelegate.swift"
      issue: "Quit-time MCP temp sweep only runs inside an async teardown Task after a 2s sleep; not guaranteed to complete before the app process is reaped on .terminateLater quit."
  missing:
    - "Run sweepMCPTempFiles() synchronously in applicationShouldTerminate before returning .terminateLater (immediate, race-free), keeping the post-grace sweep as a backstop."
  status_after_fix: resolved
  fix_commit: 30fd152
  debug_session: ""

## Follow-up (deferred — Phase 9 / JOBS-01)

- observation: "After recording, the menu returns to idle with no visible sign the background filing/investigation is running. captureState only has idle/recording/transcribing (D-08 moved filing state into FilingJob.state); MenuView never renders jobs[]. spawnFilingJob (AppState.swift:262) sets no statusText at start — only spoken announcements fire on completion."
  not_a_bug: "Visual jobs list is deliberately deferred to Phase 9 (JOBS-01), confirmed by the FilingJob.swift ForEach comment."
  minimal_option: "statusText = 'Filing issue…' while any job is .filing, cleared on done/cancel/fail."
  workaround: "pgrep -fl 'make-an-issue-mcp' detects an in-flight filing (the claude subprocess runs with --mcp-config .../make-an-issue-mcp-<uuid>.json)."
