---
phase: 03-local-transcription
verified: 2026-06-25T21:45:00Z
status: human_needed
score: 16/18
behavior_unverified: 2
overrides_applied: 0
re_verification:
  previous_status: human_needed
  previous_score: 12/12
  context: >
    Previous verification (2026-06-24) covered plans 03-01 (CLIRunner) and 03-02
    (user-configured ASR command). The phase was reopened for a bundled-whisper rework.
    Plans 03-03 and 03-04 delivered new build scripts and replaced the user-ASR surface
    entirely. This is a rework re-verification — old truths 6-12 (user-ASR) are
    superseded; the 16 rework must-haves are verified fresh below.
  gaps_closed: []
  gaps_remaining: []
  regressions: []
behavior_unverified_items:
  - truth: "Releasing the shortcut transcribes the recording with the bundled whisper binary + model — no ASR command field, no PATH setup (SC1)"
    test: "Run scripts/fetch-whisper.sh then scripts/build-app.sh; launch the assembled MakeAnIssue.app; hold push-to-talk shortcut, speak a phrase, release"
    expected: "Menu transitions Recording → Transcribing → Done; transcript text from bundled whisper-cli appears in the TranscriptCard and Console.app NSLog shows 'MakeAnIssue transcript: <text>'"
    why_human: "Requires the assembled .app (real Contents/Resources/whisper-cli + ggml-small.en.bin), a hardware microphone, and a running macOS app. The wiring is fully verified by tests (seam proves stopRecording → beginTranscription → Transcriber.run(wavURL:) → CLIRunner → whisper argv) but the actual bundled-binary invocation and round-trip cannot be confirmed without the assembled bundle."
  - truth: "The bundled whisper-cli runs locally on the dev machine via the assembled .app (ad-hoc signed; not Gatekeeper-blocked locally) (SC3)"
    test: "After scripts/build-app.sh, launch the assembled .app and trigger transcription"
    expected: "No 'cannot be opened because the developer cannot be verified' Gatekeeper dialog appears; whisper-cli executes and produces a transcript"
    why_human: "Gatekeeper/quarantine behaviour is only observable at real launch of the assembled .app. The ad-hoc codesign mechanism is verified in build-app.sh source, but whether the built binary passes Gatekeeper on the dev machine requires actual execution."
human_verification:
  - test: "Assembled .app end-to-end smoke (SC1 + SC2): scripts/fetch-whisper.sh → scripts/build-app.sh → launch MakeAnIssue.app → hold shortcut, speak, release"
    expected: "Bundled whisper-cli produces a transcript visible in the TranscriptCard and in Console.app NSLog. Menu shows Transcribing... then Done. No ASR Command field in Settings — only Push-to-Talk Shortcut and CLI Command."
    why_human: "Requires real ~466 MB whisper-cli + model, hardware microphone, and assembled .app. Cannot run in unit tests (injectable resourceBase seam was specifically added to avoid this). Deferred to /gsd-verify-work per plan."
  - test: "Gatekeeper check (SC3): verify bundled whisper-cli spawns without dialog on the dev machine"
    expected: "codesign -dv Contents/Resources/whisper-cli shows ad-hoc signature; no 'cannot be opened' dialog on launch; transcription executes."
    why_human: "Gatekeeper/quarantine behaviour only observable at real .app launch. Developer-ID signing/notarization explicitly deferred to D-04/D-05 per ROADMAP."
  - test: "scripts/fetch-whisper.sh full run (Wave-0 gap): cmake build + model download + SHA256 pinning"
    expected: "vendor/whisper-cli built at v1.9.1; vendor/ggml-small.en.bin downloaded; on first run script prints computed SHA256 and exits 1 with instructions to pin it; after pinning, re-run verifies checksum and exits 0. otool -L vendor/whisper-cli shows no /opt/homebrew/ paths."
    why_human: "Network fetch + cmake build + ~466 MB model download; MODEL_SHA256 is intentionally an unpinned sentinel (documented Wave-0 gap per plan 03-03). Cannot run in automated CI."
---

# Phase 03: Local Transcription — Verification Report (Bundled-Whisper Rework)

**Phase Goal:** Transcribe the recorded WAV with a bundled whisper model — zero configuration, no user-supplied ASR command.
**Verified:** 2026-06-25T21:45:00Z
**Status:** human_needed
**Re-verification:** Yes — rework re-verification after bundled-whisper rework (plans 03-03 + 03-04). Previous verification (2026-06-24) covered the original user-ASR implementation (plans 03-01 + 03-02). The rework superseded truths 6-12 from the previous verification.

---

## Goal Achievement

### Observable Truths

Truths are drawn from the roadmap success criteria (SC1-SC3) and PLAN frontmatter must_haves for all four plans. SC2 is absorbed into plan truth 15 (identical intent). SC1 and SC3 add the assembled .app end-to-end requirement not covered by any plan truth.

#### Roadmap Success Criteria (overarching)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC1 | Releasing the shortcut transcribes the recording with the bundled whisper binary + model — no ASR command field, no PATH setup | PRESENT_BEHAVIOR_UNVERIFIED | Wiring verified: `stopRecording()` → `beginTranscription()` → `onRunTranscription(wavURL)` → `Transcriber.run(wavURL:)` → `CLIRunner().run(whisper-cli argv)`. No `asrCommand`/`asrCommandKey` anywhere in production sources. No ASR Command field in MenuView. Assembled .app smoke requires human verification. |
| SC3 | The bundled whisper-cli runs locally on the dev machine via the assembled .app (ad-hoc signed; not Gatekeeper-blocked locally) | PRESENT_BEHAVIOR_UNVERIFIED | `codesign --force -s -` in `build-app.sh` verified. `xattr -cr` quarantine strip in `fetch-whisper.sh` verified. Whether the ad-hoc signature passes Gatekeeper on the dev machine requires assembled .app execution. Developer-ID signing correctly deferred (D-04/D-05). |

#### Plan 01 — CLIRunner

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | CLIRunner executes a command through /bin/zsh -lc and returns its stdout | VERIFIED | `CLIRunner.swift` line 83-84: `process.executableURL = URL(fileURLWithPath: "/bin/zsh")`, `process.arguments = ["-lc", command]`. `testStdoutCapture` passes (1/1). |
| 2 | CLIRunner captures stdout and stderr on separate channels; stderr never merged into stdout | VERIFIED | Two distinct `Pipe()` instances (`stdoutPipe`, `stderrPipe`); separate `readabilityHandler` on each. `testStderrSeparateFromStdout` asserts both channels independently and passes. |
| 3 | CLIRunner returns the process exit code so callers can distinguish success from failure | VERIFIED | `CLIResult.success(stdout:stderr:exitCode:)` and `CLIResult.failed(exitCode:stderr:)` carry `Int32` exit code. `testExitCodeCaptured` passes. |
| 4 | CLIRunner enforces a 120s timeout, terminates the process, and resolves the async call exactly once | VERIFIED | `NSLock`-backed `RunState.claim()` provides atomic check-then-resume (upgraded from `nonisolated(unsafe)` in `fix(03)` commit). Timeout `Task` checks `!Task.isCancelled`, calls `state.claim()` before `process.terminate()`. `testTimeoutTerminatesAndResolvesOnce` and `testTimeoutAndExitBoundaryResolvesExactlyOnce` pass. |
| 5 | CLIRunner can run in a caller-supplied working directory | VERIFIED | `process.currentDirectoryURL = wd` wired when `workingDirectory` non-nil. `testWorkingDirectoryRespected` passes. |

#### Plan 03-03 — Bundled-Whisper Build Scripts

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 6 | scripts/fetch-whisper.sh builds whisper-cli from source at pinned tag v1.9.1 via cmake Release into gitignored vendor/ | VERIFIED | `WHISPER_TAG="v1.9.1"` (line 5); `git clone --depth 1 --branch "$WHISPER_TAG"` (line 19); `cmake --build ... -j --config Release` (line 25); `cp ... "$VENDOR/whisper-cli"` (line 26). `sh -n scripts/fetch-whisper.sh` passes (syntax OK). |
| 7 | scripts/fetch-whisper.sh downloads ggml-small.en.bin from pinned Hugging Face URL and verifies SHA256 | VERIFIED | `MODEL_URL` set to HuggingFace URL (line 6). SHA256 gate: if sentinel `<sha256-to-fill-in-on-first-download>`, computes and prints digest then `exit 1` — model never used unverified (lines 40-46). `shasum -a 256 -c` verification on pinned runs (line 47). `MODEL_SHA256` is intentionally unpinned (documented Wave-0 gap per plan intent). |
| 8 | scripts/build-app.sh copies vendor artifacts into MakeAnIssue.app/Contents/Resources and ad-hoc signs whisper-cli | VERIFIED | `resources_dir="$contents_dir/Resources"` (line 27); `cp "$repo_root/vendor/whisper-cli" "$resources_dir/whisper-cli"` (line 29); `cp ... ggml-small.en.bin` (line 30); `codesign --force -s - "$resources_dir/whisper-cli"` (line 35). Existence guard exits 1 with clear message if vendor/ not populated (lines 21-25). `sh -n scripts/build-app.sh` passes. |
| 9 | The whisper-cli binary is ad-hoc signed BEFORE any outer .app signing (bottom-up order) | VERIFIED | `codesign --force -s -` on `whisper-cli` is the last step in `build-app.sh`; no outer `.app` signing exists in the script. Comment on line 33 explicitly states bottom-up order. No `notarytool` present. |
| 10 | vendor/ is listed in .gitignore so the ~466 MB binary + model never enter git history | VERIFIED | `.gitignore` line 16: `vendor/`. `grep -n "vendor/" .gitignore` confirmed. |

#### Plan 03-04 — Bundled-Whisper Transcriber Rework

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 11 | Transcriber.run(wavURL:resourceBase:) invokes bundled whisper-cli with bundled ggml-small.en.bin via generic CLIRunner — no user-supplied ASR command | VERIFIED | `Transcriber.swift` line 65-79: resolves `bundledBinaryURL`, `bundledModelURL`, builds command, calls `await CLIRunner().run(command: command)`. No `UserDefaults` read anywhere in Transcriber. `testRunConstructsCorrectCommand` passes (fake echo whisper-cli). |
| 12 | The whisper-cli argv is `'<bin>' -m '<model>' -f '<wav>' -l en -nt -t 4` with all three paths POSIX single-quote escaped | VERIFIED | `Transcriber.swift` line 77: `let command = "'\(escapedBin)' -m '\(escapedModel)' -f '\(escapedWav)' -l en -nt -t 4"`. POSIX escaping via `.replacingOccurrences(of: "'", with: "'\\''")`  on lines 71-73. `testRunConstructsCorrectCommand` asserts `-m`, `-f`, `-l en`, `-nt`, `-t 4`, and WAV path all present. |
| 13 | Transcriber resolves bundled binary and model from Bundle.main.resourceURL via bundledBinaryURL(resourceBase:) / bundledModelURL(resourceBase:), with injectable resourceBase override | VERIFIED | `Transcriber.swift` lines 27-52: `guard let base = resourceBase ?? Bundle.main.resourceURL`; throws `bundledResourcesMissing` when base is nil or file absent. `testBundledBinaryURLThrowsWhenResourcesNil` and `testBundledModelURLThrowsWhenModelAbsent` pass. |
| 14 | When bundled binary or model is missing, Transcriber throws TranscriberError.bundledResourcesMissing(detail:) and AppState resets captureState to .idle with a clear "rebuild the app" status | VERIFIED | `TranscriberError.bundledResourcesMissing(detail:)` case exists. `AppState.message(for:)` line 291-292: returns `"Whisper not bundled — rebuild the app: \(detail)"`. `captureState = .idle` on all TranscriberError paths. `testBundledResourcesMissingResetsStateAndSurfacesStatus` passes: asserts `captureState == .idle` and `statusText.lowercased().contains("rebuild the app")`. |
| 15 | The trimmed stdout transcript is stored in AppState.transcript, shown in the menu (TranscriptCard), and NSLog'd (TRANSCRIBE-02 / SC2) | VERIFIED | `AppState.swift` line 208: `self.transcript = text`; line 209: `NSLog("MakeAnIssue transcript: \(text)")`. `MenuView.swift` lines 54-56: `if let transcript = appState.transcript { TranscriptCard(transcript: transcript) }`. `TranscriptCard` has `.textSelection(.enabled)` (line 535). `testSuccessfulTranscriptionStoresText` passes. |
| 16 | AppState.onRunTranscription default closure calls Transcriber.run(wavURL:) with no UserDefaults asrCommand read; tests inject their own stub | VERIFIED | `AppState.swift` lines 96-98: default closure is `{ url in try await Transcriber.run(wavURL: url) }` — no `UserDefaults.standard.string(forKey:)` call. Seam parameter type unchanged `(URL) async throws -> String` — existing test stubs compile unchanged. |

**Score:** 16/18 truths verified (16 VERIFIED; 2 PRESENT_BEHAVIOR_UNVERIFIED — assembled .app smokes for SC1 and SC3; deferred to /gsd-verify-work by design per plan 03-03 §Manual-Only and 03-04 §Manual-Only)

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/CLIRunner.swift` | /bin/zsh -lc runner, separate stdout/stderr, 120s single-resume timeout, optional workingDirectory + environment | VERIFIED | 170 lines; `struct CLIRunner` + `enum CLIResult`; `NSLock`-backed `RunState` for single-resume; `readabilityHandler` on both pipes; `timeoutTask?.cancel()` after normal completion |
| `Tests/MakeAnIssueTests/CLIRunnerTests.swift` | Functional tests using real /bin/echo, /bin/sh | VERIFIED | 8 tests pass (expanded from original 5 with boundary + environment tests) |
| `Sources/MakeAnIssue/Transcriber.swift` | bundledBinaryURL/bundledModelURL (injectable resourceBase); run(wavURL:resourceBase:) building whisper-cli argv; reworked TranscriberError | VERIFIED | 98 lines; `struct Transcriber`; `enum TranscriberError` with `bundledResourcesMissing`; NO `prepare()`, NO `emptyCommand`, NO `missingWavToken`; `Bundle.main.resourceURL` (7 references) |
| `Tests/MakeAnIssueTests/TranscriberTests.swift` | 3 bundled-binary tests (throws when absent, model absent, correct command construction) | VERIFIED | 80 lines; `testBundledBinaryURLThrowsWhenResourcesNil`, `testBundledModelURLThrowsWhenModelAbsent`, `testRunConstructsCorrectCommand` — all pass; no old `prepare()` tests |
| `Sources/MakeAnIssue/AppState.swift` | Default onRunTranscription calls Transcriber.run(wavURL:); no asrCommandKey; message(for: .bundledResourcesMissing); cliCommandKey retained | VERIFIED | Contains `cliCommandKey` (not `asrCommandKey`); default closure `Transcriber.run(wavURL: url)`; `bundledResourcesMissing` in `message(for:)` returning "rebuild the app" string |
| `Sources/MakeAnIssue/MenuView.swift` | No ASR Command field / asrCommand @AppStorage; CLI Command and TranscriptCard retained; .transcribing case handled | VERIFIED | `@AppStorage(AppState.cliCommandKey)` (no asrCommandKey); `TranscriptCard` rendered when transcript non-nil; `.transcribing` case in `ActionCard` shows "Transcribing Audio" + spinner; `grep -c asrCommand MenuView.swift` = 0 |
| `scripts/fetch-whisper.sh` | Pinned-tag cmake build + SHA256-gated model download into vendor/; executable | VERIFIED | WHISPER_TAG="v1.9.1"; git clone --depth 1 --branch; cmake --build; SHA256 sentinel gate; executable (rwxr-xr-x) |
| `scripts/build-app.sh` | Copy vendor artifacts into Contents/Resources + codesign --force -s -; no notarytool | VERIFIED | resources_dir="$contents_dir/Resources"; both vendor cp lines; chmod +x; codesign --force -s -; no notarytool |
| `.gitignore` | vendor/ rule | VERIFIED | Line 16: `vendor/` |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AppState.swift` | `Transcriber.swift` | default `onRunTranscription` closure calls `Transcriber.run(wavURL:)` | WIRED | Line 97: `try await Transcriber.run(wavURL: url)` — no UserDefaults asrCommand read |
| `Transcriber.swift` | `CLIRunner.swift` | `Transcriber.run` invokes `CLIRunner().run(command:)` and trims stdout | WIRED | Line 79: `let result = await CLIRunner().run(command: command)` |
| `Transcriber.swift` | `Bundle.main.resourceURL` | `bundledBinaryURL`/`bundledModelURL` resolve whisper-cli and ggml-small.en.bin | WIRED | Lines 28, 44: `resourceBase ?? Bundle.main.resourceURL`; `appendingPathComponent("whisper-cli")` / `"ggml-small.en.bin"` |
| `AppState.swift` | `AudioRecorder.swift` | `beginTranscription` reads `audioRecorder.latestWavURL` to feed wavURL | WIRED | Line 198: `guard let wavURL = audioRecorder.latestWavURL else { ... }` |
| `MenuView.swift` | `AppState.swift` | `@AppStorage(AppState.cliCommandKey)` and `appState.transcript` / `captureState` | WIRED | Line 8: `@AppStorage(AppState.cliCommandKey)`; line 54: `if let transcript = appState.transcript { TranscriptCard(...) }` |
| `scripts/fetch-whisper.sh` | `vendor/whisper-cli` | cmake build at v1.9.1 + cp | WIRED | Lines 18-28: guarded build block; no prebuilt download |
| `scripts/build-app.sh` | `MakeAnIssue.app/Contents/Resources/whisper-cli` | cp vendor/whisper-cli + codesign | WIRED | Lines 27-35: resources_dir, cp, chmod +x, codesign |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| CLIRunner /bin/zsh -lc stdout capture | `swift test --filter CLIRunnerTests/testStdoutCapture` | 1/1 pass | PASS |
| CLIRunner stderr separation | `swift test --filter CLIRunnerTests/testStderrSeparateFromStdout` | 1/1 pass | PASS |
| CLIRunner 120s timeout (200ms short test) | `swift test --filter CLIRunnerTests/testTimeoutTerminatesAndResolvesOnce` | 1/1 pass | PASS |
| CLIRunner 8 tests (includes boundary + env) | `swift test --filter CLIRunnerTests` | 8/8 pass | PASS |
| Transcriber bundledBinaryURL throws when absent | `swift test --filter TranscriberTests/testBundledBinaryURLThrowsWhenResourcesNil` | 1/1 pass | PASS |
| Transcriber run constructs correct argv | `swift test --filter TranscriberTests/testRunConstructsCorrectCommand` | 1/1 pass | PASS |
| All 3 TranscriberTests | `swift test --filter TranscriberTests` | 3/3 pass | PASS |
| bundledResourcesMissing resets state | `swift test --filter AppStateTests/testBundledResourcesMissingResetsStateAndSurfacesStatus` | 1/1 pass | PASS |
| Full test suite | `swift test` (orchestrator-confirmed) | 106/106 pass | PASS |

---

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|----------------|-------------|--------|----------|
| TRANSCRIBE-01 (reworked) | 03-03, 03-04 | Transcribes recorded WAV with bundled whisper binary + bundled model — zero configuration, no user-supplied ASR command | SATISFIED (automated evidence; assembled .app smoke human-deferred) | Bundled binary/model resolved via `bundledBinaryURL`/`bundledModelURL`; whisper-cli argv built with `-l en -nt -t 4`; invoked via generic `CLIRunner`; no `asrCommand`/`asrCommandKey` anywhere in production sources; `testRunConstructsCorrectCommand` passes with fake echo binary |
| TRANSCRIBE-02 | 03-01, 03-04 | The transcription output is captured as transcript text for the request | SATISFIED | `CLIRunner` captures stdout separately; `Transcriber.run()` trims and returns it; `AppState.transcript` stores it; `NSLog` records it; `TranscriptCard` renders it with `.textSelection(.enabled)`; `testSuccessfulTranscriptionStoresText` passes |

---

### Prohibition Verification (Plan 03-04)

All six prohibitions from plan 03-04 frontmatter are satisfied:

| Prohibition | Status | Evidence |
|-------------|--------|----------|
| MenuView MUST NOT contain asrCommand @AppStorage or ASR Command field | SATISFIED | `grep -c 'asrCommand' MenuView.swift` = 0; Settings group has only Push-to-Talk Shortcut and CLI Command |
| AppState MUST NOT declare asrCommandKey nor read UserDefaults for asrCommand | SATISFIED | `grep -c 'asrCommandKey' AppState.swift` = 0; `cliCommandKey` retained |
| AppState onRunTranscription injectable closure is TEST seam only; production default calls Transcriber.run(wavURL:) directly | SATISFIED | Default closure body is `try await Transcriber.run(wavURL: url)` — no `UserDefaults.standard.string(forKey:)` call |
| Transcriber MUST NOT keep prepare(command:wavURL:) or accept user-supplied command/{wav} token | SATISFIED | `grep 'prepare(' Transcriber.swift` returns 0 matches; `grep 'emptyCommand\|missingWavToken' Transcriber.swift` returns 0 matches |
| TranscriberError MUST NOT contain emptyCommand or missingWavToken; MUST add bundledResourcesMissing | SATISFIED | `TranscriberError` has: `bundledResourcesMissing`, `asrFailed`, `asrTimedOut`, `emptyTranscript`. No `emptyCommand`, no `missingWavToken`. |
| CLIRunner MUST NOT be modified or whisper-specialized in plan 03-04 | SATISFIED | Plan 03-04 commit history confirms CLIRunner.swift NOT in files_modified for 03-04 commits. The NSLock fix (`fix(03)` commit) and environment parameter (`feat(04-01)` commit) were separate commits outside plan 03-04 scope. CLIRunner remains generic. |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `scripts/fetch-whisper.sh` | 9 | `MODEL_SHA256="<sha256-to-fill-in-on-first-download>"` | Info | Intentional unpinned sentinel (documented Wave-0 gap per plan 03-03). Script computes and prints the real SHA256 on first download then `exit 1` — model never used unverified. Not a stub; it is the specified safety mechanism. |

No unresolved debt markers (TBD/FIXME/XXX). No stub returns in production data paths. No hardcoded empty arrays/objects rendering as user-visible data.

---

### Human Verification Required

#### 1. Assembled .app End-to-End Smoke (SC1 + TRANSCRIBE-01)

**Test:** Run `scripts/fetch-whisper.sh` to populate `vendor/` (requires cmake + ~466 MB download + SHA256 pinning). Then run `scripts/build-app.sh` to produce `MakeAnIssue.app`. Launch the app, open the menu, confirm no ASR Command field appears (only Push-to-Talk Shortcut and CLI Command in Settings). Hold the push-to-talk shortcut, speak a phrase, release.

**Expected:** Menu transitions "Recording" → "Transcribing Audio" (with spinner, state badge "ASR") → "Transcription Done" → transcript text appears in `TranscriptCard`; Console.app shows `MakeAnIssue transcript: <spoken text>` from NSLog.

**Why human:** Requires the real ~466 MB `ggml-small.en.bin` model (never used in unit tests by design — injectable `resourceBase` seam), a hardware microphone, and the assembled `.app`. Unit tests verify the wiring with a fake echo binary; the real whisper inference is the unverified end of the chain.

#### 2. Gatekeeper Non-Block Check (SC3)

**Test:** After `scripts/build-app.sh`, run `codesign -dv .build/MakeAnIssue.app/Contents/Resources/whisper-cli` to confirm ad-hoc signature. Then trigger transcription via the running app.

**Expected:** `codesign -dv` shows the ad-hoc signature (not code-signed by Developer ID). Transcription executes — no "cannot be opened because the developer cannot be verified" dialog appears on the dev machine.

**Why human:** Gatekeeper behaviour is only observable at real `.app` launch. The ad-hoc codesign mechanism is in `build-app.sh` and `xattr -cr` is in `fetch-whisper.sh`, both verified. Whether this combination passes Gatekeeper locally requires actual execution. Developer-ID signing/notarization explicitly deferred (D-04/D-05).

#### 3. scripts/fetch-whisper.sh Full Run (Wave-0 Gap)

**Test:** Run `scripts/fetch-whisper.sh` on a clean machine. Observe first run exits 1 and prints a 64-char SHA256. Paste it as `MODEL_SHA256` in the script. Re-run; confirm it exits 0. Run `otool -L vendor/whisper-cli` to verify no `/opt/homebrew/` paths.

**Expected:** First run: SHA256 printed, `exit 1`. After pinning: `shasum -a 256 -c` passes, `exit 0`. `otool -L` shows only system frameworks (no Homebrew paths).

**Why human:** Network fetch + cmake build + ~466 MB download. `MODEL_SHA256` is intentionally an unpinned sentinel — the plan documents this as the Wave-0 gap requiring one manual developer run to pin the value.

---

## Gaps Summary

No gaps. All 16 plan must-have truths are VERIFIED by code inspection and targeted test runs. All 9 required artifacts exist and are substantive. All 7 key links are wired. Both TRANSCRIBE-01 (reworked) and TRANSCRIBE-02 are satisfied with implementation evidence.

Two roadmap success criteria (SC1, SC3) are PRESENT_BEHAVIOR_UNVERIFIED — code wiring and scripts are correct, but the assembled `.app` end-to-end smokes require human execution. These are explicitly deferred to `/gsd-verify-work` per plans 03-03 and 03-04 §Manual-Only. They are not implementation gaps.

All plan 03-04 prohibitions are satisfied: the user-ASR surface (`asrCommand`, `asrCommandKey`, `prepare()`, `emptyCommand`, `missingWavToken`) is fully removed from production sources, confirmed by compiler (swift build passes) and grep.

---

_Verified: 2026-06-25T21:45:00Z_
_Verifier: Claude (gsd-verifier)_
