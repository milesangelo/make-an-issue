---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
plan: "05"
subsystem: IssueResultParser
tags: [gap-closure, bug-fix, tdd, parser, permissions]
status: complete

dependency_graph:
  requires: [04-01, 04-04]
  provides: [corrected-parse-ordering]
  affects: [IssueResultParser, IssueResultParserTests]

tech_stack:
  added: []
  patterns: [url-wins-over-denial, tdd-red-green]

key_files:
  created: []
  modified:
    - Sources/MakeAnIssue/IssueResultParser.swift
    - Tests/MakeAnIssueTests/IssueResultParserTests.swift

decisions:
  - "Broad url-wins reorder chosen over config.mcpToolName-specific denial narrowing: a parsed /issues/N url is genuine proof of a filed issue regardless of which tool was denied. The simpler approach is correct and the no-url path already preserves safety."
  - "testPermissionDeniedBeatsSuccessfulToolResult rewritten (not deleted) as testSuccessfulUrlBeatsPermissionDenial to preserve coverage of the url-alongside-denial path while encoding the corrected semantic."

metrics:
  duration: "4m"
  completed: 2026-06-26
  tasks_completed: 3
  files_modified: 2
---

# Phase 04 Plan 05: Gap-Closure IssueResultParser Reorder Summary

**One-liner:** Reorder `IssueResultParser.parse` so a successfully-parsed `/issues/N` url returns before the permission-denial gate, fixing UAT Test 4 false-failure.

## What Was Built

A surgical two-line reorder in `IssueResultParser.parse` plus a regression test pinning the corrected behavior. No new public symbols, no structural changes.

### Root Cause (from 04-UAT.md)

`IssueResultParser.parse` threw `.permissionDenied` whenever `permission_denials` was non-empty — and that gate ran **before** returning the already-extracted `fromToolResult` success result. When `claude` reached for any tool outside the allowlist (e.g., `Bash`) during repo investigation, that unrelated denial populated `permission_denials` and masked the successful `issue_write` url, causing the app to display "Issue tool not granted" even though the issue was created on GitHub.

### Fix Applied

**Before (lines 110-121, old order):**
```
permission-denial gate (throws) → fromToolResult return → prose fallback → noIssueFound
```

**After (corrected order):**
```
fromToolResult return → prose fallback → permission-denial gate (only if no url found) → noIssueFound
```

The denial gate is now only reached when no url was extracted. A parsed `/issues/N` url is proof of a real side effect — it wins over any permission denial regardless of which tool was denied.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | RED — regression test + reconcile old test | f256fc8 | IssueResultParserTests.swift |
| 2 | GREEN — reorder parse logic | 159e863 | IssueResultParser.swift |
| 3 | Full suite green + build | (verification) | — |

## Test Results

- **Before:** 106 tests total; `testPermissionDeniedBeatsSuccessfulToolResult` encoded the buggy behavior (asserted throw when url was present)
- **After:** 107 tests total (+1 new regression test); all pass
- **IssueResultParserTests:** 10 tests, 0 failures
- **Full suite:** 107 tests, 0 failures
- **Build:** `swift build` — Build complete, no new warnings

### New test: `testPermissionDenialWithSuccessfulUrlReturnsResult`

Fixture: `result` envelope with `permission_denials: [{"tool_name":"Bash"}]` (unrelated tool) + `assistant` `tool_result` block with `https://github.com/acme/widget/issues/42`. Asserts parse returns `IssueFilingResult(number:42)` — not throws.

### Rewritten test: `testSuccessfulUrlBeatsPermissionDenial`

(Renamed from `testPermissionDeniedBeatsSuccessfulToolResult`.) Same fixture (url for `/issues/89` + denial for `mcp__github__issue_write`). Now asserts parse returns `IssueFilingResult(number:89)`. Comment updated to reflect corrected semantic.

### Inverse safety test (unchanged): `testPermissionDeniedDetected`

Fixture: `permission_denials` non-empty AND no url in stream. Still throws `.permissionDenied(["mcp__github__issue_write"])`. Safety preserved.

## Deviations from Plan

**Test count:** Plan estimated 112 tests (111 + 1 new). Actual count before was 106; after is 107. The plan's estimate was inaccurate; the +1 new test is correct and all tests pass. Not a behavioral deviation.

No other deviations — plan executed exactly as written, including the intentional scope note (broad url-wins reorder, no `config.mcpToolName`-specific narrowing).

## Known Stubs

None.

## Threat Flags

None. No new trust boundaries introduced. The denial gate still fires on no-url + non-empty denials (T-04-02 mitigation preserved).

## Self-Check: PASSED

- [x] `Sources/MakeAnIssue/IssueResultParser.swift` — modified (reorder applied)
- [x] `Tests/MakeAnIssueTests/IssueResultParserTests.swift` — modified (new test + rewrite)
- [x] Task 1 commit f256fc8 exists: `git log --oneline | grep f256fc8`
- [x] Task 2 commit 159e863 exists: `git log --oneline | grep 159e863`
- [x] Full suite: 107 tests, 0 failures
- [x] `swift build` — Build complete, no new warnings
