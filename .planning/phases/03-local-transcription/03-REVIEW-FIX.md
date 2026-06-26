---
phase: 03-local-transcription
fixed_at: 2026-06-25T23:45:00Z
review_path: .planning/phases/03-local-transcription/03-REVIEW.md
iteration: 1
findings_in_scope: 5
fixed: 5
skipped: 0
status: all_fixed
---

# Phase 03: Code Review Fix Report

**Fixed at:** 2026-06-25T23:45:00Z
**Source review:** .planning/phases/03-local-transcription/03-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 5 (all Warnings; the 6 Info findings are out of scope for `critical_warning`)
- Fixed: 5
- Skipped: 0

All fixes were verified by recompiling the SwiftPM package (`swift build`) and, for
the test/state-machine changes, by running the full `AppStateTests` suite (36 tests,
0 failures) three times to confirm determinism. The shell-script fix was verified with
`sh -n`.

## Fixed Issues

### WR-01: CLIRunner may drop the final stdout/stderr chunk on process exit

**Files modified:** `Sources/MakeAnIssue/CLIRunner.swift`
**Commit:** ffb9ee4
**Applied fix:** In `process.terminationHandler`, after detaching the readability
handlers, synchronously drain any residual buffered bytes via
`readDataToEndOfFile()` on both pipes and append them to the shared `RunState`
before `claim()` decodes. This prevents the tail of the transcript from being
truncated when buffered pipe data has not yet been delivered to the readability
callbacks at exit. Verified with `swift build`.

### WR-02: `curl` without `--fail` can poison the vendor cache and block all future runs

**Files modified:** `scripts/fetch-whisper.sh`
**Commit:** ed6938d
**Applied fix:** Download the model to `ggml-small.en.bin.partial` with `curl -fL`
so HTTP errors abort instead of writing an error body, verify the SHA-256 of the
temp file, and only then `mv` it into place. A failed/poisoned download never
lands at the cached path, so subsequent runs are no longer blocked. The existing
always-enforced SHA check (and the Info-scope placeholder branch, IN-02) were left
untouched. Verified with `sh -n`.

### WR-03: Startup mic-permission Task can overwrite an already-resolved grant; never re-checked

**Files modified:** `Sources/MakeAnIssue/AppState.swift`, `Tests/MakeAnIssueTests/AppStateTests.swift`
**Commit:** ba3ee35
**Applied fix:** Two changes. (1) The startup permission `Task` now only ever
*promotes* to granted (`if granted { micPermissionGranted = true }`), so a
late-resolving denied result can no longer clobber a grant. (2) `startRecording()`
re-checks live authorization before bailing out, so a grant made in System Settings
after launch is honored without relaunch. To keep this deterministic and testable
(the live `AVCaptureDevice.authorizationStatus` would otherwise depend on the test
host's TCC state), the re-check is an injectable seam `onCheckMicAuthorization`
following the codebase's existing seam pattern; the default reads the real TCC
status. The `testStartRecordingWithoutMicPermissionStaysIdleAndSurfacesStatus`
test now injects `{ false }` for a host-independent denial. Verified with
`swift build` + full `AppStateTests` run (36 passing).
**Note — requires human verification:** the `startRecording()` re-query is a
behavior change to the permission flow; confirm the live-status semantics on a real
macOS 13 and macOS 14 device (the startup request uses `AVAudioApplication` on 14
vs `AVCaptureDevice` on 13, while the re-check uses `AVCaptureDevice` on both —
they reflect the same underlying mic TCC grant but should be smoke-tested).

### WR-04: Async state-machine tests depend on fixed `Task.sleep` delays

**Files modified:** `Tests/MakeAnIssueTests/AppStateTests.swift`
**Commit:** d9e7691
**Applied fix:** Added a `waitUntil(timeout:_:)` polling helper that returns as
soon as a condition holds (or after a generous 5 s deadline) and replaced every
fixed wall-clock `Task.sleep` in the test bodies with a `waitUntil` on the actual
terminal condition (e.g. `state.captureState == .idle`, `spokenText != nil`). The
deliberate seam-internal delays (which hold a transient state in-flight) were left
intact. The transient-`.filing` observation tests now poll for `.filing` while the
slow filing seam holds it. Verified by running the suite three times: 36/36 pass
each time, and runtime dropped from ~3.86 s to ~0.87 s because the tests no longer
sleep past completion.

### WR-05: `process.terminate()` (SIGTERM) is assumed sufficient on timeout

**Files modified:** `Sources/MakeAnIssue/CLIRunner.swift`
**Commit:** 46e4b51
**Applied fix:** After the timeout path sends SIGTERM and resumes the continuation
with `.timeout`, a detached `Task` waits a 2 s grace period and, if the child is
still running, escalates to `kill(process.processIdentifier, SIGKILL)` so a
signal-ignoring child is reaped instead of lingering. The continuation is already
resolved, so this only affects reaping, not the returned result. Verified with
`swift build`.
**Note — requires human verification:** this is a concurrency/logic change. The
`process.isRunning` → `kill(pid, SIGKILL)` sequence has an inherent (and on macOS
practically negligible over a 2 s window) TOCTOU on PID reuse. Confirm the
escalation behaves as intended against a child that genuinely ignores SIGTERM.

## Skipped Issues

None — all in-scope findings were fixed.

---

_Fixed: 2026-06-25T23:45:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
