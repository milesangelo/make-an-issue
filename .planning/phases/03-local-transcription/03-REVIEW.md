---
phase: 03-local-transcription
reviewed: 2026-06-25T00:00:00Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/CLIRunner.swift
  - Sources/MakeAnIssue/MenuView.swift
  - Sources/MakeAnIssue/Transcriber.swift
  - Tests/MakeAnIssueTests/AppStateTests.swift
  - Tests/MakeAnIssueTests/CLIRunnerTests.swift
  - Tests/MakeAnIssueTests/TranscriberTests.swift
  - scripts/build-app.sh
  - scripts/fetch-whisper.sh
findings:
  critical: 2
  warning: 6
  info: 3
  total: 11
status: issues_found
---

# Phase 03: Code Review Report (bundled-whisper rework — 03-03 + 03-04)

**Reviewed:** 2026-06-25
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

This review covers the bundled-whisper rework added in plans 03-03 and 03-04:
`scripts/fetch-whisper.sh` and `scripts/build-app.sh` vendor a whisper-cli binary
and ggml model into the app bundle; `Transcriber` and `AppState` were rewired to
invoke the bundled binary via `CLIRunner`, removing the user-supplied ASR command
surface.

The previously reviewed CLIRunner concurrency findings (CR-01, WR-01 through
WR-04) are resolved and are not re-examined here. The rework introduces two new
critical issues and six warnings.

The most urgent problem is in `fetch-whisper.sh`: the `MODEL_SHA256` field was
never replaced from its placeholder sentinel. The script detects this and exits 1
with instructions on every run, meaning the script has never successfully
completed end-to-end as submitted and the supply-chain integrity guard for the
model is non-functional. The second critical issue is that `whisper-cli` is
fetched by git tag name (`v1.9.1`) without commit-hash pinning and without any
post-build checksum, leaving the binary side of the supply chain unverifiable.

The Swift rework itself is structurally sound: POSIX single-quote escaping in
`Transcriber.run` is correct, error paths reset `captureState` to `.idle`, and
the new tests cover the bundled-resource-missing and transcription-failure cases.
The warnings are smaller consistency gaps and quality issues.

## Critical Issues

### CR-01: `MODEL_SHA256` is the placeholder sentinel — script always exits 1; supply-chain guard non-functional

**File:** `scripts/fetch-whisper.sh:9`

**Issue:** `MODEL_SHA256` is committed as `"<sha256-to-fill-in-on-first-download>"` — the
sentinel value the script uses to detect that the SHA has not yet been pinned. The
detection logic on line 40 catches this, downloads the model, prints the computed
digest, and exits 1 with instructions to paste it back. This means:

1. The script has never successfully run end-to-end. Any build that depends on
   `fetch-whisper.sh` producing `vendor/ggml-small.en.bin` will fail.
2. The SHA256 integrity check on line 47 (`shasum -a 256 -c -`) is unreachable in
   the current state. The model can be substituted without detection.
3. `build-app.sh` will surface a confusing "vendor/ggml-small.en.bin not found"
   error rather than the root-cause "run fetch-whisper.sh first."

This is a shipped-incomplete implementation: the pinning step is an explicit
design requirement (the comment on lines 7-9 documents the process) that was
never completed.

**Fix:** Run the script once to download the model, capture the printed SHA256,
and replace the placeholder:

```sh
# In fetch-whisper.sh line 9 — replace the placeholder with the actual digest:
MODEL_SHA256="<64-char hex digest from shasum -a 256 vendor/ggml-small.en.bin>"
```

---

### CR-02: `whisper-cli` fetched by tag name without commit-hash pinning; no post-build binary integrity check

**File:** `scripts/fetch-whisper.sh:5,19-20`

**Issue:** The whisper.cpp source is cloned via `--branch "$WHISPER_TAG"` where
`WHISPER_TAG="v1.9.1"`. Git tags are mutable: a compromised or force-pushed tag
on `github.com/ggml-org/whisper.cpp` silently substitutes arbitrary source code
on the next fresh clone. The guard on line 18 (`[ ! -f "$VENDOR/whisper-cli" ]`)
means re-cloning only occurs when the binary is absent, so the exposure window is
the first build on any new machine or after a `vendor/` wipe.

Additionally, the compiled binary is never checksummed. The model receives a SHA256
guard (line 47), but the binary — which is executed with the user's audio files as
arguments — does not. A tampered binary in `vendor/whisper-cli` would pass
`build-app.sh` silently.

**Fix:**

1. Pin to a commit hash, not just a tag:
```sh
WHISPER_COMMIT="<40-char SHA1 of the v1.9.1 tag commit>"
# Then after clone:
git -C "$SRC" checkout "$WHISPER_COMMIT"
```

2. Add a `BINARY_SHA256` field and verify it after the build, mirroring the model
   check:
```sh
BINARY_SHA256="<64-char digest>"
printf '%s  %s\n' "$BINARY_SHA256" "$VENDOR/whisper-cli" | shasum -a 256 -c -
```

## Warnings

### WR-01: `swift build` uses debug configuration — debug binary is bundled

**File:** `scripts/build-app.sh:11,16`

**Issue:** `swift build` on line 11 with no `-c` flag defaults to the `debug`
configuration. Line 16 then copies `.build/debug/MakeAnIssue` into the `.app`
bundle. The resulting app runs unoptimized code with full debug symbols, which
degrades runtime performance and produces a much larger binary than necessary for
a functional build.

**Fix:**
```sh
swift build -c release
cp "$repo_root/.build/release/MakeAnIssue" "$macos_dir/MakeAnIssue"
```

---

### WR-02: `latestWavURL == nil` early-exit in `beginTranscription` sets `statusText` but not `transcriptError`

**File:** `Sources/MakeAnIssue/AppState.swift:198-202`

**Issue:** When `audioRecorder.latestWavURL` is nil, the early-exit path sets
`statusText` and resets `captureState` to `.idle`, but does not set
`transcriptError`. Every other failure path in `beginTranscription` (lines
217-218, 224-225) sets both `transcriptError` and `statusText`. This inconsistency
means any observer watching `transcriptError` (tests or future UI code) would see
`nil` for this specific failure case while `statusText` carries the error.

```swift
// Current — line 199-201:
captureState = .idle
statusText = "Transcription failed — recording not found"
return
```

**Fix:** Set `transcriptError` before returning, mirroring the async error paths:
```swift
captureState = .idle
let message = "Transcription failed — recording not found"
statusText = message
transcriptError = message
return
```

---

### WR-03: `CLIRunner` timeout is the default 120s — no mechanism for caller to lengthen it

**File:** `Sources/MakeAnIssue/Transcriber.swift:79`

**Issue:** `CLIRunner().run(command: command)` is called without a `timeout:`
argument, inheriting the 120s default. For long recordings (the max recording
duration is also 120s) on slower hardware, whisper-cli transcription of a
2-minute clip can exceed 120s, producing a `TranscriberError.asrTimedOut` on
audio that could have been transcribed successfully given more time.

The `Transcriber.run` signature exposes no timeout parameter, so callers (including
tests) cannot tune this without modifying the implementation.

**Fix:** Surface a configurable timeout on `Transcriber.run`:
```swift
static func run(
    wavURL: URL,
    resourceBase: URL? = nil,
    timeout: Duration = .seconds(120)
) async throws -> String {
    // ...
    let result = await CLIRunner().run(command: command, timeout: timeout)
```

---

### WR-04: Thread count is a magic number hardcoded to 4

**File:** `Sources/MakeAnIssue/Transcriber.swift:77`

**Issue:** `-t 4` is hardcoded in the whisper-cli invocation with no
explanation of why 4 was chosen. On a machine with 2 efficiency cores this
over-provisions; on M-series chips with 10+ performance cores it leaves most
of the hardware idle. The value is also invisible to callers and untestable.

**Fix:** Either derive from the hardware or define it as a named constant:
```swift
// At the top of Transcriber or as a private static let:
private static let whisperThreadCount = 4  // whisper-cli default; tunable

// In run():
let command = "'\(escapedBin)' -m '\(escapedModel)' -f '\(escapedWav)' -l en -nt -t \(Self.whisperThreadCount)"
```

---

### WR-05: Dead code in `testFilingEntersFilingState` — unused DispatchSemaphore and stray type reference

**File:** `Tests/MakeAnIssueTests/AppStateTests.swift:602-603,606,631`

**Issue:** Two pieces of dead code survive in `testFilingEntersFilingState`:

1. Lines 602-603: A `CheckedContinuation<Void, Never>.self` type reference is
   captured in a local, immediately silenced with `_ = filingStarted`, and then
   never used. This is leftover scaffolding from a prior implementation attempt.

2. Lines 606 and 631: A `DispatchSemaphore(value: 0)` is created and `.signal()`d
   at the end of the test (line 631), but `.wait()` is never called. The
   semaphore has no effect and is dead.

These are not test reliability issues (the test logic is correct), but they
indicate the test was edited without cleanup and leave misleading code in a test
that is testing a timing-sensitive state transition.

**Fix:** Remove both:
```swift
// Delete lines 602-603 (CheckedContinuation reference)
// Delete line 606 (let sem = DispatchSemaphore...)
// Delete line 631 (sem.signal())
```

---

### WR-06: Model download guard checks only file existence — partial download bypasses re-fetch

**File:** `scripts/fetch-whisper.sh:32-34`

**Issue:** The re-download guard is:
```sh
if [ ! -f "$VENDOR/ggml-small.en.bin" ]; then
    curl -L -o "$VENDOR/ggml-small.en.bin" "$MODEL_URL"
fi
```
If a prior `curl` was interrupted mid-download, a truncated or zero-byte file
is left at `$VENDOR/ggml-small.en.bin`. The guard sees the file exists and
skips re-downloading. Once `MODEL_SHA256` is pinned (see CR-01), the subsequent
SHA256 check on line 47 will fail, but the error message from `shasum -c` is
`ggml-small.en.bin: FAILED` with no guidance that a re-download is needed. The
developer must manually delete the file before the script can recover.

**Fix:** Add a minimum file-size check or unconditionally download to a temp path
and move atomically:
```sh
# Option A: check minimum plausible size (~465 MB for ggml-small.en.bin)
if [ ! -f "$VENDOR/ggml-small.en.bin" ] || [ "$(wc -c < "$VENDOR/ggml-small.en.bin")" -lt 100000000 ]; then
    curl -L -o "$VENDOR/ggml-small.en.bin.tmp" "$MODEL_URL"
    mv "$VENDOR/ggml-small.en.bin.tmp" "$VENDOR/ggml-small.en.bin"
fi
```

## Info

### IN-01: POSIX path escaping is untested with single-quote or space characters in paths

**File:** `Tests/MakeAnIssueTests/TranscriberTests.swift`

**Issue:** `testRunConstructsCorrectCommand` in `TranscriberTests` verifies that the
correct flags appear in the command by running a fake echo binary with a simple
`/tmp/test.wav` path. The POSIX single-quote escaping in `Transcriber.run`
(lines 71-73 of `Transcriber.swift`) is correct, but it is not exercised by any
test with adversarial path components such as spaces (`/tmp/my audio/test.wav`) or
embedded single quotes (`/tmp/it's there/test.wav`). A regression in the escaping
logic would pass all current tests.

**Fix:** Add two test cases with `wavURL` paths containing spaces and single
quotes, verify the correct path string appears in the echo output.

---

### IN-02: `$SRC` whisper.cpp source tree and cmake build artifacts are never cleaned up

**File:** `scripts/fetch-whisper.sh:19-29`

**Issue:** The cmake build leaves `$VENDOR/whisper.cpp-src/` intact after copying
the binary. This directory contains the full source tree plus cmake build artifacts
and can exceed 2-3 GB. If `vendor/` is ever accidentally committed (e.g., the
`.gitignore` is incomplete), this would be a very large commit. Even without
committing, it silently consumes significant disk space with no documented
expectation.

**Fix:** Remove the source tree after the binary is copied:
```sh
cp "$SRC/build/bin/whisper-cli" "$VENDOR/whisper-cli"
rm -rf "$SRC"   # clean up source + build artifacts (~2-3 GB)
```
Or document the intent to keep it (e.g., for incremental cmake rebuilds), and add
`vendor/whisper.cpp-src/` to `.gitignore`.

---

### IN-03: Main `MakeAnIssue` binary and `.app` bundle are not code-signed

**File:** `scripts/build-app.sh:35`

**Issue:** `codesign` is called only on `whisper-cli` (line 35). The main
`MakeAnIssue` binary in `MacOS/MakeAnIssue` and the `.app` bundle itself receive
no signature — not even ad-hoc. On modern macOS, launching an unsigned app from
a non-trusted location can trigger Gatekeeper dialogs. The comment references
D-04/D-05 as the deferral justification; this is a known gap, not a mistake.

**Fix (when deferred work lands):** Apply ad-hoc signing to the main binary and
the bundle after whisper-cli is signed:
```sh
codesign --force -s - "$macos_dir/MakeAnIssue"
codesign --force -s - "$app_dir"
```
Full distribution signing (Developer ID, hardened runtime) should follow in the
D-04/D-05 work item.

---

_Reviewed: 2026-06-25_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
