---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
verified: 2026-06-26T00:45:00Z
status: passed
score: 5/5 must-haves verified
behavior_unverified: 0
overrides_applied: 0
re_verification:
  previous_status: passed
  previous_score: 5/5
  gaps_closed:
    - "UAT Test 4 false-failure: IssueResultParser.parse threw .permissionDenied even when a real issue URL was parsed, because the denial gate ran before the fromToolResult return. Fixed by 04-05: url-wins reorder ensures a successfully-parsed /issues/N url is returned before the permission-denial gate is reached."
  gaps_remaining: []
  regressions: []
---

# Phase 04: Voice AI CLI Drafts + Files Issue via MCP + Spoken Confirmation — Re-Verification Report

**Phase Goal:** Hand the transcript to the user's AI coding CLI (claude/codex) running in the bound repo; the CLI investigates the repo, drafts the issue, and files it through its own configured MCP server (GitHub or Atlassian/Jira). The app parses the created issue's number/URL from stdout and speaks "created issue #NUMBER". No gh, no API token.
**Verified:** 2026-06-26T00:45:00Z
**Status:** passed
**Re-verification:** Yes — after gap closure (04-05: IssueResultParser url-wins-over-denial reorder)

## Context

The initial VERIFICATION.md (2026-06-25T19:15:00Z) marked this phase `passed` based on two human-confirmed filings (issues #90 and #91). Post-verification UAT (04-UAT.md) revealed a major false-failure: repeated filings showed "Issue tool not granted — check CLI Command config" even when the issue WAS created on GitHub. Diagnosis confirmed `IssueResultParser.parse` ran the permission-denial gate before returning the already-extracted `fromToolResult` url — any unrelated denied tool (e.g. `Bash` during repo investigation) populated `permission_denials` and masked the successful `issue_write`. Gap closure plan 04-05 reordered the logic (url found → return; only if no url AND denials → throw) and added a regression test pinning the corrected behavior.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | The app invokes the configured AI CLI with the transcript and working directory = bound repo | ✓ VERIFIED | `IssueFilingRunner.file()` calls `CLIRunner().run(command:workingDirectory:repo.rootURL:...)` — cwd = `repo.rootURL`. `AppState` default `onRunIssueFiling` closure wires transcript + repo. `AppStateTests.testFilingSeamCalledWithTranscriptAndRepo` passes (confirmed in full suite run). No changes in 04-05 touch these paths. |
| 2 | A real issue is created through the CLI's MCP server (GitHub proven). The app holds no tokens; it rides the CLI's existing OAuth session. | ✓ VERIFIED (human-confirmed) | Human checkpoint (04-04-SUMMARY.md): issues #90 and #91 filed in pulsedemon/netshooter. Token passed via `Process.environment` only — never in command string (IssueFilingRunner.swift:122–137, 164). `IssueFilingConfig.claudeGitHub` uses docker-based GitHub MCP server, no app-held credential. 04-05 made no changes to this path. |
| 3 | The created issue number/URL is parsed from the CLI's stdout (URL-path regex, never the node id). Unrelated denials do not mask a successfully-filed issue. | ✓ VERIFIED | `IssueResultParser.parse` (lines 111–123): `if let r = fromToolResult { return r }` at line 113 precedes the denial gate at lines 119–121. A successfully-parsed `/issues/N` url is returned before `!deniedTools.isEmpty` is evaluated. `testPermissionDenialWithSuccessfulUrlReturnsResult` (Bash denial + issue_write url → result.number == 42) PASSES. `testSuccessfulUrlBeatsPermissionDenial` (mcp__github__issue_write denial + `/issues/89` url → result.number == 89) PASSES. Safety invariant: `testPermissionDeniedDetected` (non-empty denials + NO url → throws `.permissionDenied(["mcp__github__issue_write"])`) PASSES. All 10 IssueResultParserTests pass. |
| 4 | The app speaks "created issue #NUMBER" via native text-to-speech | ✓ VERIFIED (human-confirmed) | `AppState.speak()` builds `AVSpeechUtterance`, stored `speechSynthesizer` calls `speak(utterance)` (AppState.swift:284–287). `beginFiling()` builds `"created issue #\(result.number)"` (AppState.swift:256). `testSuccessfulFilingSpeaksIssueNumber` asserts spoken text contains "42". Human checkpoint confirmed correct audio for issues #90 and #91. The "Issue tool not granted" false path is now gated out when a url is parsed — the TTS path is reached correctly. |
| 5 | Backend is provider-agnostic via a configurable command seam; codex + Jira explicitly documented as deferred | ✓ VERIFIED | `IssueFilingConfig` struct provides the provider seam. `claudeGitHub` static default. Doc comment states codex + Jira deferred (upstream non-interactive MCP write unreliable; zero-token Jira write may require OAuth). `MenuView` CLI Command `@AppStorage` field defaults to `"claude"`. No changes in 04-05. |

**Score:** 5/5 truths verified (0 present, behavior-unverified)

### Re-Verification: Gap Closure Confirmation (04-05 Must-Haves)

These are the specific truths introduced by plan 04-05 to close the UAT Test 4 gap. All three are subsumed by Truth 3 above but recorded separately for auditability.

| # | 04-05 Must-Have | Status | Evidence |
|---|-----------------|--------|----------|
| A | "When the AI CLI successfully files an issue, the app reports success even if an unrelated tool was denied during repo investigation" | ✓ VERIFIED | `testPermissionDenialWithSuccessfulUrlReturnsResult` fixture: `permission_denials:[{"tool_name":"Bash"}]` + issue_write url for `/issues/42` → parse returns `IssueFilingResult(number:42)`. PASSES. |
| B | "The app never shows 'Issue tool not granted' when a real issue was created on GitHub" | ✓ VERIFIED | Follows from A: `.permissionDenied` is only thrown when no url was found. The "Issue tool not granted" message (AppState.swift:334) is unreachable when a url is parsed. |
| C | "A permission denial WITH no successfully-filed issue still surfaces as an error (safety preserved)" | ✓ VERIFIED | `testPermissionDeniedDetected` fixture: `permission_denials:[{"tool_name":"mcp__github__issue_write"}]` + no url anywhere → throws `.permissionDenied(["mcp__github__issue_write"])`. PASSES. IssueResultParser.swift lines 119–121 confirm the denial gate fires only after both `fromToolResult` and prose fallback return nil. |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/IssueResultParser.swift` | JSONL tool_result walker + prose-regex fallback; IssueFilingResult, IssueParseError; url-wins-before-denial-gate ordering | ✓ VERIFIED | 149 lines; line 113 returns `fromToolResult` before line 119 denial gate; line 116 returns prose fallback before denial gate; comments updated to reflect corrected semantic. |
| `Tests/MakeAnIssueTests/IssueResultParserTests.swift` | 10 tests including `testPermissionDenialWithSuccessfulUrlReturnsResult` (new) and `testSuccessfulUrlBeatsPermissionDenial` (rewritten from testPermissionDeniedBeatsSuccessfulToolResult) | ✓ VERIFIED | 149 lines; both tests exist at lines 85 and 101; old test name absent (correctly renamed, not deleted); 10/10 pass. |
| `Sources/MakeAnIssue/IssueFilingConfig.swift` | Provider seam value type; claudeGitHub static default | ✓ VERIFIED | Unchanged by 04-05; wiring to IssueFilingRunner confirmed (no regression). |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | `IssueResultParser.parse(stdout:)` call; `.permissionDenied` error mapping | ✓ VERIFIED | Line 178: `return try IssueResultParser.parse(stdout: stdout)`; line 182–183: `.permissionDenied` → `IssueFilingError.permissionDenied(tools:)`. Unchanged by 04-05. |
| `Sources/MakeAnIssue/AppState.swift` | `.filing` state; `onRunIssueFiling` seam; TTS path | ✓ VERIFIED | Unchanged by 04-05. `.permissionDenied` message path at lines 333–334 is now only reached when no url was found (correct). |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `IssueResultParser.parse` line 113 | `IssueFilingResult` return | `if let r = fromToolResult { return r }` before denial gate | ✓ WIRED | The url-wins reorder: structured result returned before `!deniedTools.isEmpty` check at line 119. |
| `IssueResultParser.parse` line 116 | `IssueFilingResult` return (prose) | `if let r = extractFromProseText(finalResultText) { return r }` | ✓ WIRED | Prose fallback also precedes denial gate. |
| `IssueResultParser.parse` lines 119–121 | `.permissionDenied` throw | `if !deniedTools.isEmpty { throw IssueParseError.permissionDenied(deniedTools) }` | ✓ WIRED | Only reached when both url extraction paths fail. |
| `IssueFilingRunner.swift:178` | `IssueResultParser.parse` | `return try IssueResultParser.parse(stdout: stdout)` | ✓ WIRED | Unchanged by 04-05. |
| `IssueFilingRunner.swift:182–183` | `IssueFilingError.permissionDenied` | `.permissionDenied(let tools)` catch + rethrow | ✓ WIRED | Downstream mapping unchanged and correct: now only triggered for genuine no-url denials. |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| url-wins-over-denial (new regression test) | `swift test --filter IssueResultParserTests/testPermissionDenialWithSuccessfulUrlReturnsResult` | PASS — result.number == 42 | ✓ PASS |
| url-wins when mcp tool is the denied one | `swift test --filter IssueResultParserTests/testSuccessfulUrlBeatsPermissionDenial` | PASS — result.number == 89 | ✓ PASS |
| Safety: denial + no url still throws | `swift test --filter IssueResultParserTests/testPermissionDeniedDetected` | PASS — throws .permissionDenied(["mcp__github__issue_write"]) | ✓ PASS |
| Full IssueResultParserTests suite | `swift test --filter IssueResultParserTests` | 10 tests, 0 failures | ✓ PASS |
| Full suite | `swift test` | 107 tests, 0 failures | ✓ PASS |

### Probe Execution

No probe scripts declared or present for this phase. Step 7c: SKIPPED (no probe-*.sh files).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| ANALYZE-01 | 04-02, 04-04 | App invokes user's AI coding CLI with cwd = bound repo | ✓ SATISFIED | `IssueFilingRunner.file()` sets `workingDirectory: repo.rootURL` in `CLIRunner().run()` call. Unchanged by 04-05. |
| ANALYZE-02 | 04-02, 04-04 | AI CLI drafts the issue from transcript and repo context | ✓ SATISFIED | `buildPrompt()` instructs the model to "Briefly investigate the repo" and file the issue. Proven by human-verified filings. Unchanged by 04-05. |
| ISSUE-01 | 04-02, 04-04 | AI CLI files through its own MCP server; app holds no gh/API token | ✓ SATISFIED | Token in `Process.environment` only; `IssueFilingConfig.claudeGitHub` uses docker GitHub MCP server. Unchanged. |
| ISSUE-02 | 04-01, 04-04, 04-05 | App parses issue number/URL from CLI stdout (URL-path regex, not node id). False-failures on unrelated denied tools eliminated. | ✓ SATISFIED | 04-05 reorder: url returned before denial gate. `testPermissionDenialWithSuccessfulUrlReturnsResult` PASSES. `testStructuredToolResultReturnsNumberFromURLPath` PASSES (number from path, not id field). |
| FEEDBACK-01 | 04-03, 04-04, 04-05 | App speaks "created issue #NUMBER" via native macOS TTS | ✓ SATISFIED | TTS path now reliably reached when url is parsed (false-failure path closed). `testSuccessfulFilingSpeaksIssueNumber` PASSES. Human checkpoint confirmed audio for issues #90 and #91. |
| PROVIDER-01 | 04-01, 04-03 | AI backend provider-agnostic via configurable command seam; codex+Jira documented deferred | ✓ SATISFIED | `IssueFilingConfig` struct is the provider seam. Unchanged by 04-05. |
| AUTH-01 | 04-02, 04-04 | App never stores/transmits credentials; rides pre-authenticated MCP session | ✓ SATISFIED | Token only in `Process.environment`, never in command string. Unchanged by 04-05. |

All 7 phase-4 requirements verified as SATISFIED. No orphaned requirements.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | No TBD/FIXME/XXX markers found in either modified file | — | Clean |

No BLOCKER anti-patterns. No debt markers in `IssueResultParser.swift` or `IssueResultParserTests.swift`.

**Known dead enum case (unchanged, documented):** `IssueParseError.malformedOutput` is declared but never thrown. Documented in 04-04-SUMMARY.md as a known minor follow-up. Not a phase-goal gap.

### Human Verification Required

None. All human-verification items were completed at the Wave 4 (04-04) checkpoint and the gap closure does not introduce new items requiring human interaction:

- Real issues #90 and #91 filed end-to-end in pulsedemon/netshooter via voice → whisper → claude+GitHub MCP (04-04-SUMMARY.md).
- Spoken numbers were the correct small human-facing URL-path numbers.
- Negative check passed (Docker stopped → no false success, honest error shown).
- The 04-05 gap closure (url-wins reorder) is fully covered by deterministic unit tests — no new human verification required for this code path.

### Gaps Summary

No gaps. The UAT Test 4 false-failure gap is closed:

- **Root cause** (from 04-UAT.md): `IssueResultParser.parse` ran the `!deniedTools.isEmpty` denial gate before returning `fromToolResult`.
- **Fix** (04-05, commit 159e863): reordered to return `fromToolResult` first; denial gate only reached when no url was found.
- **Regression coverage** (04-05, commit f256fc8): `testPermissionDenialWithSuccessfulUrlReturnsResult` + `testSuccessfulUrlBeatsPermissionDenial` (rewritten) pin the corrected behavior; `testPermissionDeniedDetected` pins the safety invariant.
- **Full suite**: 107 tests, 0 failures.
- **No regressions** in the 5 original roadmap success criteria.

---

_Verified: 2026-06-26T00:45:00Z_
_Verifier: Claude (gsd-verifier)_
_Re-verification after gap closure: 04-05 IssueResultParser url-wins-over-denial reorder_
