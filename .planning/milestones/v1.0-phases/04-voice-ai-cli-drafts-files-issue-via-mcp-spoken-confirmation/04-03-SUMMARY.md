---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
plan: "03"
subsystem: app-state-machine
tags: [swift, appstate, tts, issue-filing, menu-view, provider-seam]
status: complete

dependency_graph:
  requires:
    - 04-01  # IssueFilingResult, IssueFilingConfig, IssueFilingError
    - 04-02  # IssueFilingRunner.file()
  provides:
    - AppState.filing CaptureState case
    - AppState.onRunIssueFiling seam (injectable)
    - AppState.beginFiling() auto-transition
    - AppState.speak() / onSpeak injectable
    - AppState.cliCommandKey
    - AppState.message(for: IssueFilingError)
    - MenuView ".filing" label
    - MenuView CLI Command @AppStorage field (PROVIDER-01)
  affects:
    - 04-04  # checkpoint will exercise the full end-to-end pipeline

tech_stack:
  added: []
  patterns:
    - "Injectable seam pattern (onRunIssueFiling mirrors onRunTranscription)"
    - "Stored AVSpeechSynthesizer to prevent premature deallocation (Pitfall 1)"
    - "beginFiling() mirrors beginTranscription() Task structure"
    - "Overloaded message(for:) for IssueFilingError alongside TranscriberError"
    - "@AppStorage(AppState.cliCommandKey) for PROVIDER-01 surface"

key_files:
  modified:
    - Sources/MakeAnIssue/AppState.swift
    - Sources/MakeAnIssue/MenuView.swift
    - Tests/MakeAnIssueTests/AppStateTests.swift

decisions:
  - "onSpeak uses optional closure (nil = real AVSpeechSynthesizer, non-nil = test stub) — avoids self-reference in default param"
  - ".finished remains in CaptureState enum but is transient; flows immediately to .filing"
  - "beginFiling() called synchronously on MainActor after transcript set in beginTranscription() Task"
  - "No-repo guard returns .idle immediately without calling onRunIssueFiling (correct — no seam call needed)"
  - "speak() is internal (not private) so tests can observe it if needed; onSpeak provides primary test surface"

metrics:
  duration: "9m"
  completed: "2026-06-25"
  tasks: 2
  files_modified: 3
  tests_added: 8
  tests_updated: 5
  tests_total: 110
---

# Phase 04 Plan 03: AppState Filing Pipeline + MenuView Summary

**One-liner:** Wired `.filing` CaptureState + injected `onRunIssueFiling` seam into `AppState`; auto-transitions transcript → filing → spoken confirmation "created issue #N" → idle; `MenuView` shows "Filing issue…" and persists CLI Command field.

## What Was Built

### Task 1: AppState extensions (TDD)

**AppState.swift additions:**
- `CaptureState.filing` case — new state entered after successful transcription
- `static let cliCommandKey = "cliCommand"` — shared UserDefaults key (matches MenuView @AppStorage)
- `private let speechSynthesizer = AVSpeechSynthesizer()` — stored property (not local — avoids Pitfall 1)
- `private let onSpeak: ((String) -> Void)?` — injectable seam; `nil` uses `self.speak()`
- `private let onRunIssueFiling: (String, RepoBinding) async throws -> IssueFilingResult` — injectable seam; default wires `IssueFilingRunner.file()`
- `beginFiling()` — called on MainActor after `transcript` is set; guards `boundRepo` non-nil; sets `.filing`; spawns Task; on success calls `speak("created issue #N")` and returns `.idle`; on `IssueFilingError` sets `statusText` and returns `.idle`
- `speak(_ text: String)` — builds `AVSpeechUtterance` and calls `speechSynthesizer.speak()`
- `private static func message(for error: IssueFilingError) -> String` — user-facing strings per error case

**Flow after this change:**
`.idle` → `.recording` → `.transcribing` → `.finished` (transient) → `.filing` → `.idle`

**AppStateTests.swift:**
- 5 existing tests updated: `.finished` assertions changed to `.idle` (`.finished` is now transient); tests now reflect the auto-filing fast-path (no boundRepo → `.idle` immediately)
- 8 new tests added under `// MARK: - Issue filing (Phase 04 Wave 3)`:
  1. `testFilingSeamCalledWithTranscriptAndRepo` — verifies seam receives correct transcript + repo
  2. `testSuccessfulFilingSpeaksIssueNumber` — verifies `onSpeak` called with string containing "42"
  3. `testSuccessfulFilingReturnsToIdle` — verifies `.idle` after success
  4. `testFilingErrorSetsStatusTextAndReturnsToIdle` — `.timeout` error → non-empty statusText + `.idle`
  5. `testFilingErrorTokenAcquisitionSetsStatus` — `.tokenAcquisitionFailed` → status mentions GitHub
  6. `testNoRepoBoundSkipsFilingAndReturnsToIdle` — no repo → seam NOT called, returns `.idle`
  7. `testTranscriptRemainsSetAfterFilingReturnsToIdle` — transcript readable after filing completes
  8. `testFilingEntersFilingState` — `.filing` state observed mid-flight (slow seam stub)

### Task 2: MenuView additions

- `@AppStorage(AppState.cliCommandKey) private var cliCommand: String = "claude"` — persisted CLI command
- `case .filing: return "Filing issue…"` in `captureStateLabel` switch — exhausts new enum case
- `LabeledContent("CLI Command") { TextField("e.g. claude", text: $cliCommand) }` — PROVIDER-01 surface below ASR Command field

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing functionality] Injectable `onSpeak` seam uses `nil` instead of `self.speak` default**
- **Found during:** Task 1 implementation
- **Issue:** Swift disallows `self.speak` as a default parameter value (no `self` in scope). The plan suggested "defaulting to `self.speak`" but that's not directly expressible in Swift.
- **Fix:** Used `((String) -> Void)? = nil` — when nil, `beginFiling()` calls `self.speak()` via explicit conditional; when non-nil, tests capture the spoken string. Achieves identical observable behavior.
- **Files modified:** Sources/MakeAnIssue/AppState.swift
- **Commit:** cdff6f1

**2. [Rule 1 - Behavior correction] Existing tests updated for .finished transience**
- **Found during:** Task 1 implementation
- **Issue:** 5 existing tests asserted `captureState == .finished` after transcription. After this plan's changes, `.finished` is immediately overwritten by `beginFiling()` (transient). Tests would fail.
- **Fix:** Updated test assertions to `.idle` (the stable state after the filing fast-path completes when no repo is bound); updated test names to reflect the new semantics.
- **Files modified:** Tests/MakeAnIssueTests/AppStateTests.swift
- **Commit:** cdff6f1

## Verification Results

- `swift test --filter AppStateTests`: 34 tests, 0 failures
- `swift build`: succeeded, no missing-case warnings
- `swift test` (full suite): 110 tests, 0 failures

## TDD Gate Compliance

- RED: New tests added (filing seam, speak, no-repo guard, etc.) — all failed to compile before AppState changes (extra argument errors, `.filing` member missing)
- GREEN: AppState.swift extended; all 34 AppStateTests pass
- REFACTOR: No refactoring needed

## Known Stubs

None. The default `onRunIssueFiling` seam wires the real `IssueFilingRunner.file()`. The default `onSpeak` nil path calls the real `AVSpeechSynthesizer`. No hardcoded empty values or placeholder text in any UI-bound path.

## Threat Flags

No new threat surface introduced beyond the boundaries already modeled in the plan's threat register (T-04-10, T-04-11). The `speak()` call uses `result.number` (an `Int`) — never user-supplied text — so no injection risk in the spoken confirmation string.

## Self-Check: PASSED

- `Sources/MakeAnIssue/AppState.swift` exists: FOUND
- `Sources/MakeAnIssue/MenuView.swift` exists: FOUND
- `Tests/MakeAnIssueTests/AppStateTests.swift` exists: FOUND
- Commit cdff6f1 exists: FOUND (feat(04-03): AppState .filing state...)
- Commit 631b2fd exists: FOUND (feat(04-03): MenuView .filing label...)
- All 110 tests green: PASSED
