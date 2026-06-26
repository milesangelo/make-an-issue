---
phase: 03-local-transcription
reviewed: 2026-06-26T05:18:00Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - scripts/fetch-whisper.sh
  - scripts/build-app.sh
  - Sources/MakeAnIssue/CLIRunner.swift
  - Sources/MakeAnIssue/Transcriber.swift
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/MenuView.swift
  - Tests/MakeAnIssueTests/CLIRunnerTests.swift
  - Tests/MakeAnIssueTests/TranscriberTests.swift
  - Tests/MakeAnIssueTests/AppStateTests.swift
findings:
  critical: 1
  warning: 6
  info: 3
  total: 10
status: issues_found
---

# Phase 03: Code Review Report

**Reviewed:** 2026-06-26T05:18:00Z
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Reviewed the two newly-reworked shell scripts (`fetch-whisper.sh`, `build-app.sh`) and the Swift transcription path (`CLIRunner`, `Transcriber`, `AppState`, `MenuView`) plus their tests. The shell-injection mitigation in `Transcriber` (POSIX single-quote escaping) is correct, the model SHA256 verification is sound, and the `AppState` state machine is well-guarded and well-tested.

However, the core data path has a genuine correctness defect: `CLIRunner` nils its pipe `readabilityHandler`s inside the `terminationHandler` without a final drain, which can silently truncate the captured stdout — the transcript that gets filed as a GitHub issue. Two further concerns affect transcript integrity (login-shell profile output contaminating stdout) and script robustness/idempotency (non-atomic model download with no `-f`/cleanup, and a non-idempotent `git clone`). One UI setting (CLI Command) is wired to nothing.

## Critical Issues

### CR-01: stdout can be silently truncated by terminationHandler/readabilityHandler race

**File:** `Sources/MakeAnIssue/CLIRunner.swift:120-134` (with `:102-110`)
**Issue:** When the process exits, two callbacks race on independent queues: the final data-bearing `readabilityHandler` invocation (delivering the last chunk still buffered in the pipe) and the `terminationHandler`. The `terminationHandler` immediately sets both `readabilityHandler`s to `nil` (lines 122-123) and then snapshots the accumulated data via `state.claim()` (line 125). If the terminationHandler wins the race, any bytes still buffered in the pipe that were not yet delivered to a handler call are never read and are lost from the snapshot.

For short outputs this usually does not manifest, but `whisper-cli`'s entire transcript is delivered on stdout. A truncated transcript is not an error — it passes the non-empty guard in `Transcriber` (`:92`) and is filed verbatim as a GitHub issue. This is silent data corruption on the primary data path.

**Fix:** Drain remaining buffered data before nilling the handlers — read to EOF in the terminationHandler before claiming (safe because the writer end has closed by then):
```swift
process.terminationHandler = { p in
    let restOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let restErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    if !restOut.isEmpty { state.appendStdout(restOut) }
    if !restErr.isEmpty { state.appendStderr(restErr) }
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    guard let (out, err) = state.claim() else { return }
    // ...
}
```

## Warnings

### WR-01: Login-shell profile output can contaminate the transcript

**File:** `Sources/MakeAnIssue/Transcriber.swift:77,79` (via `CLIRunner.swift:83-84`)
**Issue:** The whisper invocation runs through `/bin/zsh -lc`. The `-l` (login) flag causes zsh to source `.zshenv`, `.zprofile`, and `.zlogin`. Any of those that write to stdout (a banner, `echo`, `fortune`, version-manager chatter) prepends that output to whisper-cli's stdout. Because the transcript is taken as the raw stdout, that contamination becomes part of the transcript and is filed as a GitHub issue. The login shell is unnecessary for transcription since all paths are absolute.
**Fix:** For the transcription path, invoke the binary directly (set `process.executableURL` to the whisper-cli URL with an argv array) rather than through a login shell, or drop `-l` for this call. If `CLIRunner` must stay shell-based, add an argv-based execution mode for transcription so profile output cannot leak into stdout.

### WR-02: Model download is non-atomic, omits `-f`, and never cleans up on failure

**File:** `scripts/fetch-whisper.sh:54-56`
**Issue:** `curl -L -o "$VENDOR/ggml-small.en.bin" "$MODEL_URL"` writes directly to the final path. Without `-f`, an HTTP 404/5xx returns exit 0 and writes the error page into the model file. The SHA256 check (`:69`) then fails — good — but the corrupt file remains on disk. On re-run the `[ ! -f ... ]` guard (`:54`) sees the file present, skips the download, and re-fails the SHA check forever. The same permanent-stuck state results from a Ctrl-C mid-download. Recovery requires the user to manually `rm` the file, which is never suggested.
**Fix:** Use `curl -fL` to a temp path, verify, then move into place; remove the temp on failure:
```sh
tmp="$VENDOR/ggml-small.en.bin.part"
curl -fL -o "$tmp" "$MODEL_URL" || { rm -f "$tmp"; echo "download failed" >&2; exit 1; }
mv "$tmp" "$VENDOR/ggml-small.en.bin"
```

### WR-03: `git clone` step is not idempotent after a partial failure

**File:** `scripts/fetch-whisper.sh:18-29`
**Issue:** The build block is guarded only on `vendor/whisper-cli` existence. If a prior run cloned into `$SRC` but failed before `cp` (build error, interrupt), `whisper-cli` is absent so the block re-enters, but `git clone ... "$SRC"` aborts with "destination path already exists" and `set -e` exits. The user gets no guidance for this case (the helpful `rm -rf` hint at `:42-44` exists only in the dylib branch).
**Fix:** Clean or guard the clone target, e.g. `rm -rf "$SRC"` before cloning, or `if [ ! -d "$SRC/.git" ]; then git clone ...; fi`, so a re-run self-heals.

### WR-04: rpath rewrite handles only the first LC_RPATH and breaks on paths with spaces

**File:** `scripts/build-app.sh:49-53`
**Issue:** The awk extractor `found && /path /{print $2; exit}` captures only the first `LC_RPATH` and exits. If `whisper-cli` carries multiple absolute rpaths (e.g. a Homebrew path plus the build dir), the others survive as stale build-machine paths in the shipped binary. Also, `print $2` takes only the first whitespace-delimited token, so any rpath containing a space (which happens when `repo_root` contains a space, since the build rpath derives from `$SRC/build`) is truncated — `install_name_tool -delete_rpath` (`:51`) then fails on the truncated value and `set -e` aborts the build.
**Fix:** Iterate over all rpaths, deleting each non-`@loader_path` entry, and capture the full path rather than `$2`:
```sh
otool -l "$bin" | awk '/cmd LC_RPATH/{f=1} f && /^ *path /{sub(/^ *path /,""); sub(/ \(offset.*/,""); print; f=0}'
```

### WR-05: "CLI Command" setting is wired to nothing

**File:** `Sources/MakeAnIssue/MenuView.swift:78` / `Sources/MakeAnIssue/AppState.swift:99-101`
**Issue:** The Settings TextField writes the UserDefaults key `cliCommand` (`AppState.cliCommandKey`), but the filing path calls `IssueFilingRunner.file(... config: .claudeGitHub ...)`, and `IssueFilingConfig.claudeGitHub` hardcodes `cliCommand: "claude"` (`IssueFilingConfig.swift:81`). Nothing reads the `cliCommand` UserDefaults value back into the config, so editing the field has no effect — a user who sets a different command is silently ignored and still runs `claude`.
**Fix:** Read the `cliCommand` default into the config before filing (build `IssueFilingConfig` from `UserDefaults.standard.string(forKey: AppState.cliCommandKey)`), or remove the non-functional TextField until it is wired.

### WR-06: Full transcript written to the unified system log

**File:** `Sources/MakeAnIssue/AppState.swift:209`
**Issue:** `NSLog("MakeAnIssue transcript: \(text)")` writes the complete transcribed speech to the macOS unified log, which is persisted and readable via Console/`log show` by admin processes. Voice transcripts can contain sensitive content; this is a privacy exposure even though marked intentional (D-09).
**Fix:** Drop the transcript text from the log (log length or a redacted marker), gate it behind `#if DEBUG`, or use `os.Logger` with `privacy: .private` instead of `NSLog`.

## Info

### IN-01: Dead SHA-pinning bootstrap block

**File:** `scripts/fetch-whisper.sh:62-68`
**Issue:** `MODEL_SHA256` is now a real 64-char digest (`:9`), so `[ "$MODEL_SHA256" = "<sha256-to-fill-in-on-first-download>" ]` is always false and the bootstrap-print branch is unreachable. The comment at `:59-61` describes a workflow that can no longer run, which can mislead a maintainer trying to re-pin a new model.
**Fix:** Remove the dead branch, or convert the "how to compute a new SHA" guidance into a plain comment so it stays useful without being dead code.

### IN-02: `WaveformView.randomHeight` is not random

**File:** `Sources/MakeAnIssue/MenuView.swift:395-398`
**Issue:** `randomHeight(for:)` indexes a fixed array by `index % count`, returning a deterministic value. The name implies randomness that does not exist.
**Fix:** Rename to `barHeight(for:)` (or similar) to reflect the deterministic lookup.

### IN-03: Transcription uses a login shell unnecessarily

**File:** `Sources/MakeAnIssue/Transcriber.swift:77` (via `CLIRunner`)
**Issue:** All three paths passed to whisper-cli are absolute, so the `-l` login shell (needed by the filing path to resolve PATH) adds nothing here but startup cost and the stdout-contamination risk in WR-01. Noted separately as a design observation; the actionable part is WR-01.
**Fix:** Prefer argv-based direct execution for the transcription call. See WR-01.

---

_Reviewed: 2026-06-26T05:18:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
