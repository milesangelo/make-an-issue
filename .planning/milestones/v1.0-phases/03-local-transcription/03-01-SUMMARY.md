---
phase: 03-local-transcription
plan: "01"
subsystem: CLIRunner
status: complete
tags:
  - swift
  - foundation-process
  - subprocess
  - concurrency
  - timeout
  - testing

dependency_graph:
  requires:
    - Foundation (Process, Pipe, FileHandle) — built-in
    - Swift Concurrency (Task, withCheckedContinuation) — built-in
  provides:
    - CLIRunner.run(command:workingDirectory:timeout:) → CLIResult
    - CLIResult enum (success/failed/timeout)
  affects:
    - Plan 02 (Transcriber calls CLIRunner.run and maps CLIResult to TranscriberError)
    - Phase 4 (CLIRunner reused with workingDirectory set to bound repo)
    - Phase 5 (CLIRunner reused for gh issue create)

tech_stack:
  added: []
  patterns:
    - "readabilityHandler concurrent pipe drain (Pattern 1 from research)"
    - "withCheckedContinuation + terminationHandler for async Process wrapping (Pattern 2)"
    - "nonisolated(unsafe) var resumed guard for single-resume guarantee (Pitfall 2 fix)"
    - "Task-based 120s timeout mirroring AppState.scheduleRecordingTimeout"

key_files:
  created:
    - Sources/MakeAnIssue/CLIRunner.swift
    - Tests/MakeAnIssueTests/CLIRunnerTests.swift
  modified: []

decisions:
  - "CLIResult is an enum with three cases (.success, .failed, .timeout) — cleanest mapping to TranscriberError in Plan 02"
  - "struct CLIRunner (no stored state; stateless per call)"
  - "realpath() used in test for /var vs /private/var normalization on macOS"

metrics:
  duration: "101s"
  completed: "2026-06-24"
  tasks_completed: 2
  files_created: 2
---

# Phase 03 Plan 01: CLIRunner Summary

One-liner: Foundation Process wrapper executing `/bin/zsh -lc` with concurrent pipe drain,
separate stdout/stderr, and a single-resume 120s timeout — reusable by Phases 4 and 5.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create CLIRunner with separate stdout/stderr+exit capture and 120s timeout | 76f63fe | Sources/MakeAnIssue/CLIRunner.swift |
| 2 | Wave 0 functional tests for CLIRunner using real /bin/echo and /bin/sh | a0006fc | Tests/MakeAnIssueTests/CLIRunnerTests.swift |

## CLIResult Shape (for Plan 02 Transcriber)

```swift
enum CLIResult {
    case success(stdout: String, stderr: String, exitCode: Int32)
    case failed(exitCode: Int32, stderr: String)
    case timeout
}
```

## CLIRunner.run Signature (for Plan 02 Transcriber)

```swift
struct CLIRunner {
    func run(
        command: String,
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(120)
    ) async -> CLIResult
}
```

**Plan 02 mapping:** Transcriber calls `CLIRunner().run(command: substitutedCommand, workingDirectory: nil)` and maps:
- `.success(stdout, _, _)` → trim stdout → transcript text
- `.failed(exitCode, stderr)` → `TranscriberError.asrFailed(exitCode:stderr:)`
- `.timeout` → `TranscriberError.asrTimedOut`

## Implementation Notes

**Pipe drain (Pitfall 1 / T-03-04):** Both stdout and stderr use separate `Pipe` instances
with `readabilityHandler` attached BEFORE `process.run()`. The EOF sentinel (empty `Data`)
is skipped. Never calls `readDataToEndOfFile()`.

**Single-resume guard (Pitfall 2 / T-03-03):** `nonisolated(unsafe) var resumed = false`
is declared inside the `withCheckedContinuation` closure. `terminationHandler` checks-then-sets
it. The timeout Task also checks `!Task.isCancelled, !resumed` before setting it and calling
`process.terminate()`. Exactly one path resumes the continuation.

**Login shell (D-02):** `process.arguments = ["-lc", command]` — the `-l` flag is mandatory
so Homebrew tools in `/opt/homebrew/bin` are found.

**Timeout (D-12):** Default `.seconds(120)`, matching `AppState.maxRecordingDuration`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed symlink normalization in testWorkingDirectoryRespected**

- **Found during:** Task 2 — first test run
- **Issue:** `URL.resolvingSymlinksInPath()` returned `/var/folders/...` but shell `pwd` returns `/private/var/folders/...` (macOS `/var` → `/private/var` symlink)
- **Fix:** Used POSIX `realpath()` C function instead to get the canonical path, matching what the subprocess reports
- **Files modified:** Tests/MakeAnIssueTests/CLIRunnerTests.swift
- **Commit:** a0006fc

## Verification Results

- `swift build` — success, no errors
- `swift test --filter CLIRunnerTests` — 5 tests pass (stdout, stderr separation, exit code, timeout, working directory)
- `swift test` (full suite) — 43 tests, 0 failures (38 baseline + 5 new CLIRunner tests)

## Threat Model Coverage

| Threat | Mitigation | Implemented |
|--------|-----------|-------------|
| T-03-02 (stdout/stderr separation) | Separate Pipe instances, returned as distinct fields | Yes — two distinct Pipe() objects, CLIResult.success has separate stdout/stderr |
| T-03-03 (hung subprocess DoS) | 120s timeout + process.terminate() + single-resume guard | Yes |
| T-03-04 (pipe-buffer deadlock DoS) | readabilityHandler on both pipes | Yes |

## Known Stubs

None — CLIRunner is fully implemented with no placeholder values.

## Self-Check: PASSED

- [x] Sources/MakeAnIssue/CLIRunner.swift exists
- [x] Tests/MakeAnIssueTests/CLIRunnerTests.swift exists
- [x] Commit 76f63fe exists
- [x] Commit a0006fc exists
- [x] 5 CLIRunner tests pass, 0 failures in full suite
