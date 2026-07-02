---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
reviewed: 2026-06-26T00:43:00Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - Sources/MakeAnIssue/IssueResultParser.swift
  - Tests/MakeAnIssueTests/IssueResultParserTests.swift
findings:
  critical: 0
  warning: 2
  info: 1
  total: 3
status: issues_found
---

# Phase 04-05: Code Review Report

**Reviewed:** 2026-06-26T00:43:00Z
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

Reviewed the gap-closure reorder (plan 04-05) in `IssueResultParser.parse`. The change moves the
`permission_denials` gate from *before* url extraction to *after* it, so a successfully-parsed
issue url returns before the denial gate fires. The denial gate is preserved at the tail: when no
url is found AND `deniedTools` is non-empty, `.permissionDenied` is thrown.

The reorder is mechanically correct and the safety semantic for the **structured tool_result**
path is intact — a `tool_result` url is strong proof the GitHub MCP `issue_write` actually
returned a created issue, so it legitimately wins over an unrelated denial (e.g. a blocked `Bash`
investigation call). All 10 tests pass, including the two new UAT-regression tests.

However, the reorder applies url-wins to **both** the structured path and the weaker **prose
fallback** path. A prose url is not equivalent proof of filing — it can be a referenced or
hallucinated url in the model's narration. With the new ordering, a prose url now also suppresses
a genuine `issue_write` denial, which silently weakens the "denial + no real filing → throw"
safety guarantee for the prose case. This edge is untested. Details below.

## Warnings

### WR-01: Prose-fallback url now overrides a permission denial — weakens the safety gate

**File:** `Sources/MakeAnIssue/IssueResultParser.swift:113-121`
**Issue:**
The reorder makes *both* the structured and prose url paths win over `permission_denials`:

```swift
if let r = fromToolResult { return r }                 // strong proof — correct to win
if let r = extractFromProseText(finalResultText) { return r }   // weak proof — also wins now
if !deniedTools.isEmpty { throw .permissionDenied(deniedTools) }
```

A structured `tool_result` url is strong evidence the MCP `issue_write` call returned a created
issue. A prose url is weaker — it comes from the model's free-text `result` string and may be a
reference to a similar/existing issue, a template example, or a hallucinated number for an issue
that was never created. The real safety case this gate protects against is: `issue_write` itself
is denied, so no issue is filed, yet exit code is 0. In that scenario there is no `tool_result`
url, but the model's prose could still contain a `https://github.com/.../issues/N` string. With
this ordering, that prose match returns `success` and the denial is silently swallowed — a false
positive that reports "issue filed" when it was not.

The plan's stated intent ("url-wins so an *unrelated* denial doesn't mask a *successful* filing")
is fully served by letting only the structured `tool_result` url win. Extending url-wins to the
prose path goes beyond that intent and erodes the gate.

**Fix:** Keep structured-url-wins, but evaluate the denial gate before the weaker prose fallback,
so a denial only loses to strong (structured) proof:

```swift
// Strong proof of filing — wins over any denial.
if let r = fromToolResult { return r }

// No structured url. A denial here means the filing did not succeed; prose is not
// strong enough to override it.
if !deniedTools.isEmpty {
    throw IssueParseError.permissionDenied(deniedTools)
}

// No denial — fall back to prose.
if let r = extractFromProseText(finalResultText) { return r }

throw IssueParseError.noIssueFound
```

If the team deliberately wants prose to also override denials, document that decision explicitly
and add a test (see WR-02) so the weakened semantic is intentional rather than incidental.

### WR-02: Missing test for the prose-url + denial edge case

**File:** `Tests/MakeAnIssueTests/IssueResultParserTests.swift:69-115`
**Issue:**
The new tests cover (a) structured url + unrelated denial → success
(`testPermissionDenialWithSuccessfulUrlReturnsResult`, `testSuccessfulUrlBeatsPermissionDenial`)
and (b) denial + no url → throw (`testPermissionDeniedDetected`, whose prose is "I was unable to
call the tool." with no url). The combination that the reorder actually changed for the weaker
path — **denial present AND only a prose url (no `tool_result`)** — is not tested. This is exactly
the boundary where WR-01's risk lives, and it currently passes silently with whatever behavior the
ordering happens to produce.

**Fix:** Add a test that pins the intended behavior. If WR-01 is accepted (denial beats prose):

```swift
func testPermissionDenialBeatsProseOnlyUrl() throws {
    // No tool_result url; the model's prose mentions an issues url but issue_write was denied.
    // The prose url is not proof of filing — the denial must win.
    let stdout = """
    {"type":"result","subtype":"success","is_error":false,"result":"I could not file it; see https://github.com/owner/repo/issues/7 for a similar one.","session_id":"s10","total_cost_usd":0.01,"num_turns":1,"permission_denials":[{"tool_name":"mcp__github__issue_write","tool_use_id":"toolu_001","tool_input":{}}]}
    """
    XCTAssertThrowsError(try IssueResultParser.parse(stdout: stdout)) { error in
        XCTAssertEqual(error as? IssueParseError, .permissionDenied(["mcp__github__issue_write"]))
    }
}
```

If the current behavior (prose beats denial) is intended, write the inverse assertion instead, so
the choice is explicit and regression-protected.

## Info

### IN-01: `.malformedOutput` error case is declared but never thrown

**File:** `Sources/MakeAnIssue/IssueResultParser.swift:19`
**Issue:**
`IssueParseError.malformedOutput` is defined but `parse` never throws it — malformed JSON lines
are silently skipped (`continue` at line 77) and an all-malformed stream resolves to
`.noIssueFound` (verified by `testMalformedJSONLinesAreSkipped`). This is dead surface area in the
public error enum and can mislead callers into writing an unreachable `catch` arm. Not introduced
by this diff, so out of strict scope, but adjacent to the reviewed logic.

**Fix:** Either remove the unused case, or document on the enum that malformed lines are
tolerated and the case is reserved for future use. No behavior change required.

---

_Reviewed: 2026-06-26T00:43:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
