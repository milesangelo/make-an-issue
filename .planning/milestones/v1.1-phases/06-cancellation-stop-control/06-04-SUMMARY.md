---
phase: 06-cancellation-stop-control
plan: "04"
subsystem: cancellation
status: complete
tags: [cancellation, quit-teardown, AppDelegate, applicationShouldTerminate, tempfile-sweep, process-groups, SIGTERM, SIGKILL]
dependency_graph:
  requires:
    - 06-03 (cancelAll() + forceKillAllProcessTrees() entry points in AppState)
  provides:
    - applicationShouldTerminate-quit-hook-AppDelegate
    - sweepMCPTempFiles-static-method
    - AppDelegateTests-sweep-isolation
    - AppDelegateTests-fast-path-terminateNow
  affects: []
tech_stack:
  added: []
  patterns:
    - defer-on-async-Task-cleanup (NSApp.reply guarantee inside teardown Task)
    - SIGTERM-grace-SIGKILL ordering (cancelAll before 2s sleep before forceKill)
    - parameterised-static-sweep (sweepMCPTempFiles(in:) for unit testability)
    - prefix-and-suffix-scoped file deletion (both conditions required to delete)
key_files:
  created:
    - Tests/MakeAnIssueTests/AppDelegateTests.swift
  modified:
    - Sources/MakeAnIssue/AppDelegate.swift
decisions:
  - "sweepMCPTempFiles is static and takes a directory parameter (default: temporaryDirectory) so unit tests can point it at a controlled directory without touching the real temp dir"
  - "cancelAll() (SIGTERM) called synchronously before returning .terminateLater so docker --rm gets the signal before any Task.sleep delay (D-04 ordering)"
  - "defer { NSApp.reply(toApplicationShouldTerminate: true) } placed inside teardown Task body — guarantees reply fires even if sweepMCPTempFiles or forceKillAllProcessTrees were to throw unexpectedly"
metrics:
  duration: "~10 minutes"
  completed: "2026-06-29"
  tasks_completed: 2
  files_modified: 2
requirements:
  - CANCEL-03
---

# Phase 06 Plan 04: Quit-Time Teardown Summary

**One-liner:** applicationShouldTerminate sequences cancelAll (SIGTERM) → 2s async grace → forceKillAllProcessTrees (SIGKILL) → sweepMCPTempFiles, all inside a defer-guaranteed NSApp.reply, with prefix+suffix-scoped tempfile deletion tested for isolation.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | applicationShouldTerminate quit hook + sweepMCPTempFiles(in:) | 8c875f2 | AppDelegate.swift |
| 2 | AppDelegateTests — sweep isolation + fast-path terminateNow | 191ce12 | AppDelegateTests.swift (new) |

## Verification Results

- `swift build` — green after Task 1 (0.71s)
- `swift test --filter AppDelegateTests` — 2 passed, 0 failures
- `swift test` (full suite) — 136 passed, 0 failures (134 baseline + 2 new tests)
- `grep -c 'func applicationShouldTerminate' AppDelegate.swift` — 1
- `grep -c 'appState.cancelAll()' AppDelegate.swift` — 1
- `grep -c 'forceKillAllProcessTrees' AppDelegate.swift` — 1
- `grep -c 'reply(toApplicationShouldTerminate' AppDelegate.swift` — 1
- `grep -c 'defer { NSApp.reply' AppDelegate.swift` — 1
- `grep -c 'make-an-issue-mcp-' AppDelegate.swift` — 2 (prefix in sweep + comment)
- SIGTERM ordering: `appState.cancelAll()` called before `Task.sleep`, `forceKillAllProcessTrees()` called after — source-confirmed
- `.terminateLater` returned only on in-flight path; `.terminateNow` only on fast path — source-confirmed

## New Behaviors

### AppDelegate.swift

**`applicationShouldTerminate(_:)` (Task 1):**

Fast path (no `.filing` jobs): calls `Self.sweepMCPTempFiles()` and returns `.terminateNow`.

Slow path (one or more `.filing` jobs):
1. Calls `appState.cancelAll()` immediately — sends Swift `Task.cancel()` to all in-flight filing tasks, which propagates to the `withTaskCancellationHandler` in CLIRunner that sends group SIGTERM to the process tree (D-04 ordering — docker `--rm` gets SIGTERM before any sleep delay)
2. Returns `.terminateLater`
3. Spawns a `@MainActor` teardown `Task` with:
   - `defer { NSApp.reply(toApplicationShouldTerminate: true) }` — guarantee reply fires on every exit path including unexpected errors (SC-4, T-6-03)
   - `try? await Task.sleep(for: .seconds(2))` — async 2s grace (never blocks main thread; D-04 docker `--rm` cleanup window)
   - `appState.forceKillAllProcessTrees()` — SIGKILL any SIGTERM survivors (T-6-01 guard: pgid > 0)
   - `Self.sweepMCPTempFiles()` — remove remaining MCP tempfiles

**`sweepMCPTempFiles(in:)` (Task 1):**

`static func sweepMCPTempFiles(in directory: URL = FileManager.default.temporaryDirectory)` — enumerates `directory` via `contentsOfDirectory(at:includingPropertiesForKeys:)`, and for each URL whose `lastPathComponent` satisfies BOTH:
- `hasPrefix("make-an-issue-mcp-")` AND
- `hasSuffix(".json")`

calls `try? FileManager.default.removeItem(at:)`. Never throws — all file operations use `try?`. The directory parameter defaults to the real temporary directory; the quit hook calls it as `Self.sweepMCPTempFiles()` (no argument). Tests call `AppDelegate.sweepMCPTempFiles(in: controlledDir)`.

### AppDelegateTests.swift (new file, Task 2)

**`testSweepRemovesOnlyMCPTempFiles`:**
Creates four files in a controlled temp directory:
- `make-an-issue-mcp-<uuid>.json` (x2) — matching, must be deleted
- `make-an-issue-mcp-keep` (no `.json` suffix) — wrong suffix, must survive
- `unrelated-<uuid>.json` (wrong prefix) — must survive

Calls `AppDelegate.sweepMCPTempFiles(in: controlledDir)`. Asserts both matching files are gone and both non-matching files remain. This is the required CANCEL-03 unit proof and T-6-06 mitigation verification.

**`testTerminateNowWhenNoFilingJobs`:**
Constructs `AppDelegate()`. A fresh `AppState` has `jobs == []`. Calls `delegate.applicationShouldTerminate(NSApplication.shared)` and asserts result is `.terminateNow`. Confirms the fast path returns without hanging.

## Deviations from Plan

None — plan executed exactly as written. The `static` keyword on `sweepMCPTempFiles` matches the plan's artifact spec; the `applicationShouldTerminate` and `sweepMCPTempFiles` implementations follow the plan's `<action>` verbatim.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes introduced. Changes are confined to AppKit quit sequence and temp directory enumeration.

STRIDE threat register mitigations confirmed present:

| Threat | Status |
|--------|--------|
| T-6-02 (SIGKILL-before-SIGTERM — leaked docker container) | Mitigated: `cancelAll()` (SIGTERM) called synchronously before returning `.terminateLater`, before the 2s `Task.sleep`; `forceKillAllProcessTrees()` (SIGKILL) called only after the grace |
| T-6-03 (app hangs in Quit — no reply) | Mitigated: `defer { NSApp.reply(toApplicationShouldTerminate: true) }` inside teardown Task; `testTerminateNowWhenNoFilingJobs` verifies fast path |
| T-6-06 (overly broad tempfile sweep — deletes unrelated files) | Mitigated: `hasPrefix("make-an-issue-mcp-") && hasSuffix(".json")` dual guard; `testSweepRemovesOnlyMCPTempFiles` asserts wrong-prefix and wrong-suffix files survive |

## Known Stubs

None. The quit hook calls the real `cancelAll()` and `forceKillAllProcessTrees()` from AppState (06-03). The sweep uses the real `FileManager`. No placeholder data flows to the UI from this plan.

## Manual Gate (CANCEL-03 / Environment Availability)

With Docker Desktop + `claude` available: run the app, start a real filing, quit mid-flight. Within the 2s grace:
- `pgrep -f claude` must return empty (process dead)
- `docker ps` must show no `github-mcp-server` container
- `ls $TMPDIR/make-an-issue-mcp-*.json` must return no files

Unit tests use the sweep + sleep-proxy; the real claude/docker path has no CI fixture. This real-process check is the developer's final phase acceptance gate.

## Self-Check: PASSED

- `Sources/MakeAnIssue/AppDelegate.swift` — exists, modified ✓
- `Tests/MakeAnIssueTests/AppDelegateTests.swift` — exists, created ✓
- Commit 8c875f2 (Task 1) — present in git log ✓
- Commit 191ce12 (Task 2) — present in git log ✓
- `swift test` — 136 passed, 0 failures ✓
