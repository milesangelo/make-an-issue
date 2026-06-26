---
status: diagnosed
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
source:
  - 04-01-SUMMARY.md
  - 04-02-SUMMARY.md
  - 04-03-SUMMARY.md
  - 04-04-SUMMARY.md
started: 2026-06-26T05:50:37Z
updated: 2026-06-26T06:05:00Z
---

## Current Test

[testing complete]

## Tests

### 1. CLI Command Field Persists
expected: Menu shows a "CLI Command" field (default "claude") below the ASR Command field. Editing it and reopening the menu retains the value (persisted via @AppStorage).
result: pass

### 2. Voice → Issue Filed (Happy Path)
expected: With a repo bound and Docker + claude CLI + gh auth ready, push-to-talk and speak an issue description. App transcribes, shows "Filing issue…", files a REAL GitHub issue in the bound repo, then speaks "created issue #N" and returns to Idle. The issue appears on GitHub.
result: pass

### 3. "Filing issue…" Status Shown Mid-Flight
expected: While the AI CLI is working (after transcription, before confirmation), the menu shows the "Filing issue…" label so you can see filing is in progress.
result: pass

### 4. Spoken Confirmation Uses Correct Issue Number
expected: The spoken/visible confirmation says the small human-facing issue number (e.g. "#91") matching the number GitHub assigned — NOT a long internal node id.
result: issue
reported: "yes, however, this has only worked once. stopped working after 'Issue tool not granted - check CLI Command config' has been displayed on the view (which is weird, because i still see the issues created in github!)"
severity: major
note: Issue number was correct on the one successful run. The defect is a false-failure: app shows a permission/tool-not-granted error while the issue IS actually created on GitHub.

### 5. Filing Failure Is Honest (Negative Safety)
expected: With the MCP backend unavailable (e.g. Docker stopped), speaking an issue files NOTHING on GitHub, speaks NO false success, shows an accurate status like "Couldn't confirm an issue was filed — check GitHub (is Docker running?)", and returns to Idle.
result: pass
note: Tested with `colima stop`. App attempts to investigate/file, then shows an accurate "Docker may not be running" warning. No false success.

### 6. No Repo Bound Skips Filing Gracefully
expected: With no repo bound, recording/transcription completes but no filing is attempted — the app returns to Idle without errors or a false "created issue" message.
result: skipped
reason: User can't easily unbind the repo to test this path. (Covered by unit test testNoRepoBoundSkipsFilingAndReturnsToIdle in AppStateTests.)

## Summary

total: 6
passed: 4
issues: 1
pending: 0
skipped: 1
blocked: 0

## Gaps

- truth: "After the AI CLI successfully files an issue, the app shows an accurate success confirmation — it never displays 'Issue tool not granted' when the issue was in fact created on GitHub."
  status: failed
  reason: "User reported: works once, then shows 'Issue tool not granted - check CLI Command config' on the view even though the issues ARE created in GitHub. False-failure status — permission/tool-not-granted error reported despite successful issue creation."
  severity: major
  test: 4
  root_cause: "IssueResultParser.parse gates on `permission_denials` non-empty and throws .permissionDenied BEFORE returning the successfully-extracted issue URL (fromToolResult). When claude reaches for ANY tool outside the allowlist (mcp__github__issue_write Read Grep Glob) during repo investigation, that unrelated denial populates permission_denials and masks the successful issue_write. The denial gate should not fire when a valid issue URL was found."
  artifacts:
    - path: "Sources/MakeAnIssue/IssueResultParser.swift"
      issue: "Lines 110-113: `if !deniedTools.isEmpty { throw .permissionDenied }` runs before the success return at line 116. A successful issue_write URL is discarded if any unrelated tool was denied."
    - path: "Sources/MakeAnIssue/IssueFilingRunner.swift"
      issue: "Lines 182-183: maps IssueParseError.permissionDenied -> IssueFilingError.permissionDenied (faithful passthrough; no change needed here, but downstream of root cause)."
    - path: "Sources/MakeAnIssue/AppState.swift"
      issue: "Lines 333-334: renders .permissionDenied as 'Issue tool not granted — check CLI Command config' — the misleading message the user sees."
  missing:
    - "Reorder IssueResultParser.parse: if a valid issue URL was extracted (fromToolResult or prose fallback), return it BEFORE the permission-denial gate — a successful issue_write is proof the issue was filed regardless of other denied tools."
    - "Optionally narrow the denial gate to fire only when the DENIED tool is the issue-writing MCP tool (config.mcpToolName) AND no URL was found, rather than on any non-empty permission_denials."
    - "Add/adjust IssueResultParserTests: a stream containing BOTH a non-empty permission_denials (for an unrelated tool, e.g. Bash) AND a successful issue_write URL must return the IssueFilingResult, not throw .permissionDenied. Keep the existing test where denials + NO url still throws."
  debug_session: "Diagnosed inline during UAT — root cause confirmed by reading IssueResultParser.swift:65-122, IssueFilingRunner.swift:182-183, AppState.swift:333-334."
