---
phase: 03-local-transcription
reviewed: 2026-06-26T05:32:37Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - scripts/build-app.sh
  - scripts/fetch-whisper.sh
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/CLIRunner.swift
  - Sources/MakeAnIssue/MenuView.swift
  - Sources/MakeAnIssue/Transcriber.swift
  - Tests/MakeAnIssueTests/AppStateTests.swift
  - Tests/MakeAnIssueTests/CLIRunnerTests.swift
  - Tests/MakeAnIssueTests/TranscriberTests.swift
findings:
  critical: 0
  warning: 5
  info: 6
  total: 11
status: issues_found
---

# Phase 03: Code Review Report

**Reviewed:** 2026-06-26T05:32:37Z
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Reviewed the local-transcription slice: two vendor/build shell scripts, the
transcription state machine (`AppState`), the generic process runner
(`CLIRunner`), the `Transcriber` wrapper, the `MenuView` UI, and three test
files. Overall the code is careful and well-commented — the single-resume
continuation guard in `CLIRunner`, the POSIX single-quote escaping in
`Transcriber`, the SHA-256 model pin in `fetch-whisper.sh`, and the
`[weak self]` discipline in `AppState` are all correct and defend against real
hazards.

No Critical/BLOCKER defects were found (the package builds cleanly against the
macOS 13 target; the `MainActor.assumeIsolated` calls are back-deployed and
compile). The findings below are correctness/robustness risks worth fixing:
the most material is a potential loss of the transcript's final bytes when the
ASR process exits (`CLIRunner` detaches pipe handlers without a final drain),
and a `curl` invocation in `fetch-whisper.sh` that can poison the vendor cache
on an HTTP error and then block every subsequent run.

## Narrative Findings (AI reviewer)

## Warnings

### WR-01: CLIRunner may drop the final stdout/stderr chunk on process exit

**File:** `Sources/MakeAnIssue/CLIRunner.swift:120-134`
**Issue:** The `terminationHandler` immediately sets both
`readabilityHandler`s to `nil` ("Detach handlers first so no stale chunk
arrives after exit") and then decodes whatever has accumulated so far. GCD does
not guarantee that every `readabilityHandler` callback for buffered pipe data
has run before `terminationHandler` fires. Any bytes still sitting in the pipe
buffer at exit are discarded when the handler is niled, so the captured output
can be truncated. For this app the discarded bytes are the **tail of the
transcript** — the primary product of the feature — making this a data-loss /
incorrect-output risk that grows with transcript length.
**Fix:** After the process exits, synchronously read any residual data before
decoding, e.g.:
```swift
process.terminationHandler = { p in
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    // Drain whatever remained buffered at exit.
    let restOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    if !restOut.isEmpty { state.appendStdout(restOut) }
    let restErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    if !restErr.isEmpty { state.appendStderr(restErr) }
    guard let (out, err) = state.claim() else { return }
    ...
}
```

### WR-02: `curl` without `--fail` can poison the vendor cache and block all future runs

**File:** `scripts/fetch-whisper.sh:54-55`
**Issue:** `curl -L -o "$VENDOR/ggml-small.en.bin" "$MODEL_URL"` omits `--fail`.
On an HTTP error (404, rate limit, redirect-to-login HTML) `curl` exits `0` and
writes the error body into `ggml-small.en.bin`. `set -e` does not catch it. The
SHA-256 check on line 69 then fails loudly (good), but the download guard on
line 54 (`[ ! -f "$VENDOR/ggml-small.en.bin" ]`) sees the poisoned file already
present on every subsequent run, skips re-download, and the SHA check fails
**forever** until the file is manually deleted.
**Fix:** Use `--fail` and download to a temp path that is only moved into place
after verification:
```sh
tmp="$VENDOR/ggml-small.en.bin.partial"
curl -fL -o "$tmp" "$MODEL_URL"
printf '%s  %s\n' "$MODEL_SHA256" "$tmp" | shasum -a 256 -c -
mv "$tmp" "$VENDOR/ggml-small.en.bin"
```

### WR-03: Startup mic-permission Task can overwrite an already-resolved grant; never re-checked

**File:** `Sources/MakeAnIssue/AppState.swift:142-148`
**Issue:** The designated `init` fires an async Task that awaits
`requestMicrophonePermission()` and then unconditionally assigns
`self?.micPermissionGranted = granted`. Two problems:
(1) In tests, code sets `state.micPermissionGranted = true` synchronously right
after construction; the still-suspended init Task later resumes and can write
back `false` (in a headless/CI environment where the request resolves denied),
flipping the flag mid-test — a latent flakiness source. (2) In the app, the
permission is requested exactly once at launch; if the user grants access in
System Settings afterward, `micPermissionGranted` is never re-read, so
push-to-talk keeps reporting "access denied" until relaunch.
**Fix:** Guard the assignment so it only ever promotes to granted
(`if granted { self?.micPermissionGranted = true }`), and re-query
authorization status at `startRecording()` time (or on app activation) instead
of caching a one-shot result.

### WR-04: Async state-machine tests depend on fixed `Task.sleep` delays

**File:** `Tests/MakeAnIssueTests/AppStateTests.swift:127,201,230,296,414,623,658`
**Issue:** Many tests advance the async transcription/filing pipeline by
sleeping a fixed wall-clock interval (e.g. `Task.sleep(for: .milliseconds(100))`)
and then asserting terminal state. These pass on an idle machine but are
inherently timing-dependent; under CI load the awaited Task may not have settled,
producing intermittent failures (and `testFilingEntersFilingState` /
`testPushToTalkDuringFilingIsIgnored` rely on observing the *transient* `.filing`
state inside a 150 ms window). Flaky tests erode trust in the suite.
**Fix:** Drive completion deterministically — e.g. have the injected
`onRunTranscription`/`onRunIssueFiling` seams signal a continuation/expectation
the test awaits, rather than sleeping a guessed duration.

### WR-05: `process.terminate()` (SIGTERM) is assumed sufficient on timeout

**File:** `Sources/MakeAnIssue/CLIRunner.swift:157`
**Issue:** On timeout the runner claims the resume slot, calls
`process.terminate()` (SIGTERM), and resumes `.timeout`. If the child ignores
SIGTERM (or is mid-`exec` of a wrapper that re-spawns), the process is never
reaped and lingers after `run` returns `.timeout`. The continuation is already
resolved, so there is no later opportunity to escalate to SIGKILL. For the
bundled whisper-cli this is unlikely, but the runner is generic (also used for
the AI-CLI filing path with much longer-running children).
**Fix:** Consider escalating to `process.interrupt()`/SIGKILL if the process is
still running shortly after `terminate()`, or document that callers must only
pass signal-respecting children.

## Info

### IN-01: KeyboardShortcuts handlers are appended per instance and never removed

**File:** `Sources/MakeAnIssue/AppState.swift:128-139`
**Issue:** `KeyboardShortcuts.onKeyDown`/`onKeyUp` append to a global handler
list (confirmed in the dependency source) and `AppState` has no `deinit` that
removes them. The single-instance app is unaffected (and `[weak self]` makes
stale handlers no-ops), but every `AppState` constructed in the test suite
leaves a permanent handler registered for the process lifetime.
**Fix:** Not required for the single-instance app; if multiple instances ever
exist, remove handlers in `deinit` via `KeyboardShortcuts.removeHandler` /
`disable(_:)`.

### IN-02: Unreachable placeholder branch in SHA-pin check

**File:** `scripts/fetch-whisper.sh:62-68`
**Issue:** `MODEL_SHA256` is already pinned to a real 64-char digest (line 9),
so the `if [ "$MODEL_SHA256" = "<sha256-to-fill-in-on-first-download>" ]`
branch can never execute. It is dead bootstrap scaffolding.
**Fix:** Remove the placeholder branch now that the digest is pinned, or keep it
intentionally as documented re-pin tooling (state the intent in a comment).

### IN-03: `DYLIBS` list duplicated across two scripts

**File:** `scripts/build-app.sh:21` and `scripts/fetch-whisper.sh:34`
**Issue:** The six-entry `DYLIBS` list is hand-maintained in two places. If
whisper.cpp changes its linked dylib set on a future bump, the lists can drift
and produce a partially-bundled `.app` that fails to load at runtime.
**Fix:** Derive the bundled set from `otool -L vendor/whisper-cli`, or factor
the list into a single sourced file shared by both scripts.

### IN-04: Neither shell script sets `pipefail`

**File:** `scripts/build-app.sh:2`, `scripts/fetch-whisper.sh:2`
**Issue:** Both use `set -eu` but not `pipefail`, so a failure in the left side
of a pipe (e.g. `otool -l ... | awk ...` at build-app.sh:49, or
`shasum ... | awk ...` at fetch-whisper.sh:64) is masked by a succeeding tail
command. These are `/bin/sh` scripts, so `pipefail` is only portable under a
POSIX shell that supports it; gate accordingly.
**Fix:** Add `set -o pipefail` where the interpreter supports it, or check
intermediate results explicitly.

### IN-05: `WaveformView.randomHeight(for:)` is misnamed — it returns fixed heights

**File:** `Sources/MakeAnIssue/MenuView.swift:395-398`
**Issue:** The method name promises randomness but indexes into a fixed array,
so every "waveform" render is identical. Purely cosmetic/naming.
**Fix:** Rename to e.g. `barHeight(for:)`, or actually randomize if variation is
desired.

### IN-06: Dead scaffolding in `testFilingEntersFilingState`

**File:** `Tests/MakeAnIssueTests/AppStateTests.swift:602-603,606,631`
**Issue:** `let filingStarted = CheckedContinuation<Void, Never>.self` assigns a
*type* and is immediately silenced with `_ = filingStarted`; a `DispatchSemaphore`
is created and only `signal()`-ed at the end (never waited on). This is leftover
scaffolding that adds noise and implies synchronization that does not occur.
**Fix:** Delete the unused `filingStarted` and `sem` declarations; the test's
real synchronization is the `Task.sleep` windows.

---

_Reviewed: 2026-06-26T05:32:37Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
