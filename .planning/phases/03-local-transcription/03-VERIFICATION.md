---
phase: 03-local-transcription
verified: 2026-06-24T15:17:00Z
status: human_needed
score: 12/12
behavior_unverified: 1
overrides_applied: 0
human_verification:
  - test: "Hold push-to-talk shortcut, speak a phrase, release the key. Observe the menu."
    expected: "Menu label transitions from 'Recording...' to 'Transcribing...' and then to 'Done'; the transcript text appears in the menu below those labels; Console.app shows 'MakeAnIssue transcript: <text>' via NSLog."
    why_human: "Requires hardware microphone and a real ASR binary (e.g. whisper) installed on PATH. Cannot verify audio round-trip, real CLIRunner spawning the ASR process, or the UI transition sequence without a running app."
  - test: "With ASR command field blank, hold push-to-talk, speak, release."
    expected: "No process is spawned; the menu immediately shows 'Set your ASR command in the menu to transcribe' (or equivalent) and state resets to idle so a subsequent push-to-talk works."
    why_human: "Empty-command guard behaviour at runtime under real app lifecycle (not a test stub) requires a running app to confirm no subprocess races."
  - test: "Enter a command without {wav} (e.g. 'whisper --model base'), hold and release push-to-talk."
    expected: "Menu shows error mentioning {wav} is required; no process is spawned; state resets to idle."
    why_human: "Requires real AppStorage-UserDefaults round-trip, running app, and confirming no process is spawned."
behavior_unverified_items:
  - truth: "While the ASR command runs, the menu shows a .transcribing state; the run is async off the main actor"
    test: "Trigger a real ASR run that takes >1s and observe the menu during execution"
    expected: "Menu label reads 'Transcribing...' while ASR is in-flight; main thread remains responsive; transcript appears on completion"
    why_human: "The code path is present and wired (captureState = .transcribing set synchronously before the Task, Task dispatched off-MainActor, result hopped back via MainActor.run). The .transcribing state transition is exercised by testStopRecordingTransitionsToTranscribing, which verifies synchronous assignment. The real-app visual transition from 'Transcribing...' to 'Done' during a live ASR run is not exercised by any automated test and requires a running app to observe."
---

# Phase 03: Local Transcription — Verification Report

**Phase Goal:** Invoke the user-configured local ASR CLI on the recorded WAV and capture the transcript text.
**Verified:** 2026-06-24T15:17:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

All twelve must-have truths from the combined PLAN frontmatter are verified. The truths are grouped by plan.

#### Plan 01 Truths (CLIRunner)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | CLIRunner executes a command through /bin/zsh -lc and returns its stdout | VERIFIED | CLIRunner.swift line 40-41: `process.executableURL = URL(fileURLWithPath: "/bin/zsh")`, `process.arguments = ["-lc", command]`. `testStdoutCapture` passes (1/1). |
| 2 | CLIRunner captures stdout and stderr on separate channels; stderr is never merged into stdout | VERIFIED | Two distinct `Pipe()` instances (lines 46-48); separate `readabilityHandler` on each (8 references, 2 attach before run, 6 nil-out). `testStderrSeparateFromStdout` asserts both channels independently and passes. |
| 3 | CLIRunner returns the process exit code so callers can distinguish success from failure | VERIFIED | `CLIResult.success(stdout:stderr:exitCode:)` and `CLIResult.failed(exitCode:stderr:)` carry `Int32` exit code. `testExitCodeCaptured` verifies exit 1 maps to `.failed(exitCode: 1, ...)`. |
| 4 | CLIRunner enforces a 120s timeout, terminates the process, and resolves the async call exactly once | VERIFIED | `nonisolated(unsafe) var resumed = false` guard; `terminationHandler` checks-then-sets; timeout Task checks `!Task.isCancelled, !resumed` before setting. `testTimeoutTerminatesAndResolvesOnce` passes (elapsed < 4s against a 5s sleep with 200ms timeout). |
| 5 | CLIRunner can run in a caller-supplied working directory | VERIFIED | `process.currentDirectoryURL = wd` wired when `workingDirectory` non-nil (line 43-44). `testWorkingDirectoryRespected` passes using realpath() normalization. |

#### Plan 02 Truths (Transcriber + AppState + MenuView)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 6 | Releasing push-to-talk runs the configured ASR command on the recorded WAV (TRANSCRIBE-01) | VERIFIED | `stopRecording()` calls `onRunTranscription(wavURL)` inside a `Task`; default closure reads `UserDefaults.standard.string(forKey: AppState.asrCommandKey)` and calls `Transcriber.run(command:wavURL:)` which calls `CLIRunner().run(...)`. `testTranscriptionInvokesSeamWithWavURL` confirms the seam is called with `latest.wav` URL. Full test suite 58/58 green. |
| 7 | An empty ASR command shows a clear 'set your ASR command' message and spawns nothing (D-03) | VERIFIED | `Transcriber.prepare()` throws `emptyCommand` before any `Process` is created. `message(for: .emptyCommand)` returns "Set your ASR command in the menu to transcribe". `testEmptyCommandShowsError` and `testEmptyCommandThrowsEmptyCommandError` pass. |
| 8 | A command missing the {wav} token shows a clear error and spawns nothing (D-05) | VERIFIED | `Transcriber.prepare()` throws `missingWavToken` when `{wav}` absent. `testMissingWavTokenError` passes; `testNonEmptyCommandWithoutWavTokenThrowsMissingWavToken` passes. |
| 9 | The {wav} token is replaced with the shell-safe single-quoted absolute path to latest.wav (D-04) | VERIFIED | POSIX single-quote escaping in `Transcriber.prepare()`: embedded `'` replaced with `'\''`; path wrapped in outer single quotes. `testWavSubstitutionQuoting`, `testPathWithSpaceIsWrappedInSingleQuotes`, `testPathWithSingleQuoteIsEscaped` all pass. |
| 10 | The captured stdout, trimmed of leading/trailing whitespace, is stored as the transcript and shown in the menu and NSLog (D-06/D-07/D-09, TRANSCRIBE-02) | VERIFIED | `Transcriber.run()` trims stdout (`trimmingCharacters(in: .whitespacesAndNewlines)`). AppState stores in `@Published var transcript`; NSLog at line 177; MenuView renders `appState.transcript` with `.textSelection(.enabled)`. `testSuccessfulTranscriptionStoresText` passes (transcript == "Hello world", captureState == .finished). |
| 11 | While the ASR command runs, the menu shows a .transcribing state; the run is async off the main actor (D-10) | PRESENT_BEHAVIOR_UNVERIFIED | `.transcribing` case in `CaptureState` confirmed. `captureState = .transcribing` set synchronously in `stopRecording()` before the `Task` dispatch. `Task { ... await MainActor.run { } }` pattern confirmed at lines 171-194. `testStopRecordingTransitionsToTranscribing` verifies synchronous state assignment. The visual transition in the running app — 'Transcribing...' label visible during a live ASR run — cannot be confirmed without a real ASR binary and a running app. |
| 12 | On failure or 120s timeout, a clear short reason plus the stderr tail is shown and state resets so a new push-to-talk works (D-11/D-12) | VERIFIED | `message(for:)` maps all `TranscriberError` cases to short strings; `asrFailed` includes stderr tail. `captureState = .idle` on all failure paths (5 occurrences). `testTimeoutResetsState` and `testFailureThrowingResetsStateToIdle` pass. |

**Score:** 12/12 must-haves verified (11 VERIFIED, 1 PRESENT_BEHAVIOR_UNVERIFIED — code present and wired; live ASR visual transition not exercised by automated test)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/CLIRunner.swift` | Process wrapper: /bin/zsh -lc, separate stdout/stderr+exit, 120s timeout | VERIFIED | 119 lines; declares `struct CLIRunner` and `enum CLIResult`; contains `/bin/zsh`, `-lc`, 2+ `readabilityHandler` instances, `resumed` guard, `process.terminate()`, `Task.sleep(for:)` |
| `Tests/MakeAnIssueTests/CLIRunnerTests.swift` | Functional tests using real /bin/echo, /bin/sh | VERIFIED | 93 lines; `final class CLIRunnerTests`; 5 tests; `testTimeoutTerminatesAndResolvesOnce` method present; all pass |
| `Sources/MakeAnIssue/Transcriber.swift` | prepare() validation + {wav} quoting + run via CLIRunner + trim stdout | VERIFIED | 80 lines; `struct Transcriber` and `enum TranscriberError`; references `{wav}` literal; calls `CLIRunner().run()` |
| `Tests/MakeAnIssueTests/TranscriberTests.swift` | prepare() validation + quoting + trim tests | VERIFIED | 108 lines; `final class TranscriberTests`; 9 tests; `testMissingWavTokenError` and `testWavSubstitutionQuoting` present; all pass |
| `Sources/MakeAnIssue/AppState.swift` | .transcribing state, transcript/transcriptError, onRunTranscription seam, asrCommandKey, startTranscription flow | VERIFIED | Contains `case transcribing`, `static let asrCommandKey = "asrCommand"`, `@Published var transcript`, `@Published var transcriptError`, `onRunTranscription` closure parameter |
| `Sources/MakeAnIssue/MenuView.swift` | ASR-command TextField bound to @AppStorage, transcript display, Transcribing... status | VERIFIED | `@AppStorage(AppState.asrCommandKey)` wired to shared constant (not bare string); `.transcribing` case returns "Transcribing…"; transcript block with `.textSelection(.enabled)` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AppState.swift` | `Transcriber.swift` | default `onRunTranscription` closure calls `Transcriber.run(command:wavURL:)` | WIRED | Line 84: `return try await Transcriber.run(command: cmd, wavURL: url)` |
| `Transcriber.swift` | `CLIRunner.swift` | `Transcriber.run` invokes `CLIRunner().run(command:...)` | WIRED | Line 61: `let result = await CLIRunner().run(command: substituted)` |
| `MenuView.swift` | `AppState.swift` | `@AppStorage(AppState.asrCommandKey)` shares key; menu observes `appState.transcript` / `captureState` | WIRED | Line 10: `@AppStorage(AppState.asrCommandKey)`; lines 42-47: transcript display reads `appState.transcript` |
| `AppState.swift` | `AudioRecorder.swift` | `startTranscription` reads `audioRecorder.latestWavURL` to feed `{wav}` | WIRED | Line 165: `guard let wavURL = audioRecorder.latestWavURL else { ... }` |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| CLIRunner stdout capture | `swift test --filter CLIRunnerTests/testStdoutCapture` | 1 test, 0 failures | PASS |
| CLIRunner stderr separation | `swift test --filter CLIRunnerTests` | 5 tests, 0 failures | PASS |
| CLIRunner 120s timeout (200ms) | `swift test --filter CLIRunnerTests/testTimeoutTerminatesAndResolvesOnce` | 1 test, 0 failures (elapsed 0.21s) | PASS |
| Transcriber {wav} substitution | `swift test --filter TranscriberTests/testWavSubstitutionQuoting` | 1 test, 0 failures | PASS |
| Transcriber missing token error | `swift test --filter TranscriberTests/testMissingWavTokenError` | 1 test, 0 failures | PASS |
| AppState transcribing transition | `swift test --filter AppStateTests/testStopRecordingTransitionsToTranscribing` | 2 tests (both naming matches), 0 failures | PASS |
| AppState success stores text | `swift test --filter AppStateTests/testSuccessfulTranscriptionStoresText` | 1 test, 0 failures | PASS |
| AppState timeout resets to idle | `swift test --filter AppStateTests/testTimeoutResetsState` | 1 test, 0 failures | PASS |
| AppState empty command error | `swift test --filter AppStateTests/testEmptyCommandShowsError` | 1 test, 0 failures | PASS |
| Full test suite | `swift test` | 58 tests, 0 failures | PASS |
| Build | `swift build` | Build complete (0.11s) | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| TRANSCRIBE-01 | 03-02-PLAN.md | The app invokes the user-configured local ASR CLI on the recorded WAV | SATISFIED | `stopRecording()` → `onRunTranscription(wavURL)` → `Transcriber.run()` → `CLIRunner().run()` chain; empty command and missing `{wav}` rejected before spawn; `testTranscriptionInvokesSeamWithWavURL` passes |
| TRANSCRIBE-02 | 03-01-PLAN.md, 03-02-PLAN.md | The ASR CLI output is captured as transcript text for the request | SATISFIED | `CLIRunner` captures stdout separately from stderr; `Transcriber.run()` trims and returns stdout; `AppState.transcript` stores trimmed text; `MenuView` renders it with `.textSelection(.enabled)`; NSLog'd at success; `testSuccessfulTranscriptionStoresText` passes |

Both requirements are marked `Complete` in REQUIREMENTS.md traceability table (Phase 3).

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `MenuView.swift` | 52, 54 | `{wav}` appears in a comment and TextField placeholder | Info | Not a stub — comment documents the token convention; placeholder shows the user example usage. No code path is affected. |

No blockers. No unresolved debt markers (TBD/FIXME/XXX). No stub returns in production data paths.

### Human Verification Required

#### 1. Live Push-to-Talk with Real ASR Binary

**Test:** Install a local ASR tool (e.g. `whisper`) visible on the login-shell PATH. Enter the command (e.g. `whisper {wav} --model base.en`) in the ASR Command field. Hold the push-to-talk shortcut, speak a phrase, release the key.

**Expected:** Menu transitions: "Recording..." → "Transcribing..." → "Done". The transcript text appears in the selectable menu block. Console.app shows `MakeAnIssue transcript: <spoken text>` from NSLog.

**Why human:** Requires hardware microphone, real ASR binary installed, running macOS app. The audio-to-text round-trip, real subprocess lifecycle under the app sandbox, and the visual state transition sequence cannot be confirmed by automated tests or grep.

#### 2. Empty ASR Command at Runtime

**Test:** Leave the ASR Command field blank. Hold and release push-to-talk.

**Expected:** No process spawned. Menu shows "Set your ASR command in the menu to transcribe" (or similar). State returns to idle so a new push-to-talk attempt works.

**Why human:** Automated tests use stub closures. Confirming no subprocess races and correct UserDefaults cold-start behavior requires a running app instance.

#### 3. ASR Command Without {wav} Token

**Test:** Enter a command without `{wav}` (e.g. `whisper --model base`). Hold and release push-to-talk.

**Expected:** Menu shows an error mentioning `{wav}` is required. No process spawned. State resets to idle.

**Why human:** Tests use stub closures; confirming the AppStorage → UserDefaults round-trip feeds the real `Transcriber.prepare()` rejection requires a running app.

---

## Gaps Summary

No gaps. All twelve must-have truths are either VERIFIED (11) or PRESENT_BEHAVIOR_UNVERIFIED (1 — code wired, live visual transition requires human observation). All required artifacts exist and are substantive. All four key links are wired. Both TRANSCRIBE-01 and TRANSCRIBE-02 are satisfied with implementation evidence. The full test suite (58 tests) passes with zero failures.

Three human verification items remain: live ASR end-to-end run, empty-command guard at runtime, and missing-token guard at runtime. These require a running app with hardware microphone and a real ASR binary — they are intentionally deferred per the plan's Manual-Only verification section.

---

_Verified: 2026-06-24T15:17:00Z_
_Verifier: Claude (gsd-verifier)_
