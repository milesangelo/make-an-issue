---
phase: 03-local-transcription
reviewed: 2026-06-24T00:00:00Z
depth: standard
files_reviewed: 7
files_reviewed_list:
  - Sources/MakeAnIssue/CLIRunner.swift
  - Sources/MakeAnIssue/Transcriber.swift
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/MenuView.swift
  - Tests/MakeAnIssueTests/CLIRunnerTests.swift
  - Tests/MakeAnIssueTests/TranscriberTests.swift
  - Tests/MakeAnIssueTests/AppStateTests.swift
findings:
  critical: 1
  warning: 4
  info: 2
  total: 7
status: issues_found
---

# Phase 03: Code Review Report

**Reviewed:** 2026-06-24
**Depth:** standard
**Files Reviewed:** 7
**Status:** issues_found

## Summary

Phase 03 adds local ASR transcription: a `CLIRunner` subprocess wrapper, a pure
`Transcriber` validator/quoter, and the async transcription flow wired into
`AppState`. The shell-safety work in `Transcriber.prepare` is correct (POSIX
single-quote escaping is properly implemented and well-tested), and the
`AppState` failure paths reset state to `.idle` so a new push-to-talk works.

However, the central concurrency guarantee that the whole `CLIRunner` design
rests on — "the continuation is resumed exactly once" — is **not actually
provided** by the implementation. The single-resume `resumed` flag is a plain
`Bool` shared across three concurrent contexts (termination handler, timeout
task, spawn-failure path) with no synchronization. This is a textbook
check-then-act data race that can double-resume a `CheckedContinuation` and
crash the process. The accumulator `Data` values share the same flaw. These are
exactly the pitfalls the code comments claim to defend against, but
`nonisolated(unsafe)` only silences the compiler — it does not make the access
safe.

Secondary issues: the recording-timeout recovery path silently discards the
captured audio instead of transcribing it, the global keyboard-shortcut closures
hold a strong reference to `AppState`, and the timeout `Task` lingers (sleeping
up to the full timeout) after every successful run.

## Critical Issues

### CR-01: `resumed` flag is a data race — `CheckedContinuation` can be resumed twice (crash)

**File:** `Sources/MakeAnIssue/CLIRunner.swift:72`, `:81-82`, `:100-101`, `:110-111`

**Issue:** `resumed` is declared `nonisolated(unsafe) var resumed = false` and is
read-and-written from three contexts that run on different threads with no lock,
actor, or atomic:

1. `process.terminationHandler` (line 81-82) — fires on a Foundation background
   dispatch queue.
2. The timeout `Task` (line 110-111) — runs on the cooperative thread pool.
3. The spawn-failure `catch` (line 100-101) — runs synchronously on the caller.

The guard pattern `guard !resumed else { return }; resumed = true` is a
check-then-act with no atomicity. When a process is terminated right around the
timeout boundary, the timeout `Task` and `terminationHandler` can execute
concurrently. Two interleavings are possible:

- Both threads read `resumed == false` before either writes `true` → both call
  `continuation.resume(...)` → Swift traps with `SWIFT TASK CONTINUATION MISUSE:
  tried to resume its continuation more than once`, which is a fatal crash.
- Because there is no memory barrier, a `resumed = true` written by one thread is
  not guaranteed to be visible to the other, so the guard cannot be relied upon
  at all.

`nonisolated(unsafe)` does not provide synchronization — it only suppresses the
Swift concurrency checker's diagnostic. The comment on lines 69-71 ("Foundation
serialises … Only one path wins") is incorrect: Foundation serialises calls to a
*single* handler, but the timeout `Task` is a wholly separate execution context.
The existing `testTimeoutTerminatesAndResolvesOnce` test does not catch this — it
only asserts a single happy-path timeout resolves; it never exercises the
concurrent terminate-vs-timeout boundary that triggers the double resume.

**Fix:** Serialize the flag with an actual lock (or use
`withCheckedContinuation` together with an `os_unfair_lock` / `NSLock` / a small
actor). Minimal lock-based fix:

```swift
let lock = NSLock()
nonisolated(unsafe) var resumed = false

@Sendable func resumeOnce(_ make: () -> CLIResult) {
    lock.lock()
    if resumed { lock.unlock(); return }
    resumed = true
    lock.unlock()
    continuation.resume(returning: make())
}
```

Then call `resumeOnce { .success(...) }`, `resumeOnce { .failed(...) }`, and
`resumeOnce { .timeout }` from each site. The compare-and-set under the lock
guarantees exactly one resume and establishes the happens-before needed for the
accumulator reads (see WR-01).

## Warnings

### WR-01: `stdoutData` / `stderrData` accumulators are read without a memory barrier

**File:** `Sources/MakeAnIssue/CLIRunner.swift:55-56`, `:59-67`, `:84-85`

**Issue:** `stdoutData` and `stderrData` are `nonisolated(unsafe) var` appended
from the `readabilityHandler` callbacks (a background dispatch queue) and read in
`terminationHandler` (a different queue) at lines 84-85. The code nils the
handlers (lines 78-79) before reading and reasons that this makes the data
"stable," but:

- Nil-ing a `readabilityHandler` does not synchronously wait for an in-flight
  handler invocation to finish; a callback already executing on another thread
  can still be mutating the `Data` while `terminationHandler` reads it.
- Even after the last append, there is no happens-before edge between the writer
  thread and the reader thread, so the appended bytes are not guaranteed visible.

This can produce truncated/garbled transcripts intermittently, especially for
large ASR output (the very case the concurrent-drain design exists to handle).

**Fix:** Guard all access to the accumulators with the same lock introduced in
CR-01 (append under the lock in the handlers; read under the lock in the resume
path). Acquiring/releasing the lock establishes the required memory ordering.

### WR-02: Recording-timeout recovery discards the captured audio instead of transcribing it

**File:** `Sources/MakeAnIssue/AppState.swift:216-222` (vs `:157-195`)

**Issue:** When the max-recording-duration timeout fires, `recordingDidTimeout()`
calls `onStopRecording()` and sets `captureState = .finished`, but it never runs
transcription. The normal `stopRecording()` path stops the recorder and then
kicks off `onRunTranscription(wavURL)`. So a user who holds push-to-talk past the
120s cap gets their recording silently dropped — the WAV is finalized on disk but
the transcript the user was speaking is thrown away, and the UI shows "Done"
("finished") as if it succeeded. This is a surprising data-loss-of-intent path.

**Fix:** Either route the timeout through the same transcription path as a normal
stop, or make the status text explicit that the recording was discarded (not
"Done"). If transcription is intended, factor the stop+transcribe sequence into a
shared private method and call it from both `stopRecording()` and
`recordingDidTimeout()`. At minimum, set a status that does not imply success and
do not transition to `.finished` (which renders as "Done").

### WR-03: Global keyboard-shortcut closures retain `AppState` strongly (retain cycle)

**File:** `Sources/MakeAnIssue/AppState.swift:106-117`

**Issue:** `KeyboardShortcuts.onKeyDown(for:)` and `onKeyUp(for:)` capture
`[self]` (strong). These closures are stored in the process-global
`KeyboardShortcuts` registry for the lifetime of the app, so they hold a strong
reference to `AppState` that is never released — a retain cycle
(`AppState` → global handler → `AppState`). The surrounding code deliberately
uses `[weak self]` everywhere else (lines 100, 120, 227), so this is an
inconsistency, not a style choice. For a single app-lifetime `AppState` the leak
is currently benign, but any code path that constructs a second `AppState`
(including tests that create many instances) will leak each one and leave stale
handlers wired to dead instances firing on the live hotkey.

**Fix:** Capture `[weak self]` and guard, mirroring the other closures:

```swift
KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
    MainActor.assumeIsolated {
        guard let self, self.captureState != .recording else { return }
        self.startRecording()
    }
}
```

### WR-04: Timeout `Task` is never cancelled and lingers after every successful run

**File:** `Sources/MakeAnIssue/CLIRunner.swift:108-116`

**Issue:** The timeout `Task` is spawned but never stored or cancelled. On the
normal (non-timeout) exit path, `terminationHandler` resumes the continuation and
returns, but the timeout `Task` keeps sleeping for the full `timeout` (120s by
default). It only wakes, sees `resumed == true`, and exits after the sleep
elapses. Until then it retains `process`, both `Pipe`s, and the closure state.
For a fast ASR command this means every transcription leaves a ~120s zombie task
holding subprocess resources. Under rapid push-to-talk use these accumulate.

**Fix:** Capture the `Task` handle and cancel it from the resume path (or hold it
in a local and `.cancel()` it inside `terminationHandler` / the spawn-failure
branch once the continuation is resumed). With the lock-based `resumeOnce` from
CR-01, cancel the timeout task immediately after a successful resume.

## Info

### IN-01: User-configured command executed via `/bin/zsh -lc` (intended, but worth flagging)

**File:** `Sources/MakeAnIssue/CLIRunner.swift:40-41`, `Sources/MakeAnIssue/AppState.swift:82-84`

**Issue:** The ASR command is read from `UserDefaults` (the user's own `@AppStorage`
text field) and executed verbatim through `/bin/zsh -lc`. This is by design — the
user is running their own shell command on their own machine, so it is not an
injection vulnerability under this threat model. The only externally-influenced
substitution (`{wav}` → file path) is correctly POSIX single-quote escaped in
`Transcriber.prepare`. Flagging for awareness: if this command string ever becomes
settable from a non-local source (config sync, URL handler, MDM profile), it
becomes arbitrary code execution. No action required for the current local-only
design.

### IN-02: `Transcriber` cannot surface a spawn failure distinctly from an ASR exit failure

**File:** `Sources/MakeAnIssue/CLIRunner.swift:99-104`, `Sources/MakeAnIssue/Transcriber.swift:67-68`

**Issue:** When the subprocess fails to spawn (e.g. `process.run()` throws because
`/bin/zsh` is missing or sandbox-denied), `CLIRunner` returns
`.failed(exitCode: -1, stderr: error.localizedDescription)`. `Transcriber.run`
maps any `.failed` to `asrFailed`, so the user sees "ASR failed (exit -1) — …"
which conflates a launch failure with the ASR tool exiting non-zero. Minor UX/
diagnosability nit; consider a distinct `CLIResult.spawnFailed` case if launch
failures need their own message.

---

_Reviewed: 2026-06-24_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
