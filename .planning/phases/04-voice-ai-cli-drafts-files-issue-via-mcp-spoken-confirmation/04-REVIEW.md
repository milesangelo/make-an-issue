---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
reviewed: 2026-06-25T00:00:00Z
depth: deep
files_reviewed: 6
files_reviewed_list:
  - Sources/MakeAnIssue/IssueResultParser.swift
  - Sources/MakeAnIssue/IssueFilingConfig.swift
  - Sources/MakeAnIssue/IssueFilingRunner.swift
  - Sources/MakeAnIssue/CLIRunner.swift
  - Sources/MakeAnIssue/AppState.swift
  - Sources/MakeAnIssue/MenuView.swift
findings:
  critical: 1
  warning: 4
  info: 2
  total: 7
status: issues_found
---

# Phase 04: Code Review Report

**Reviewed:** 2026-06-25
**Depth:** deep
**Files Reviewed:** 6 (plus 5 test files cross-referenced)
**Status:** issues_found

## Summary

Reviewed the six changed Swift source files and traced the full call chain
transcript → `AppState.beginFiling` → `IssueFilingRunner.file` → `CLIRunner.run` →
`IssueResultParser.parse`, plus the five test files. This is advisory only.

**The security posture is sound.** The four flagged security concerns from the
prompt all hold up under scrutiny:

- **Shell-escaping (command injection):** Correct. The transcript is embedded as
  prose text inside `buildPrompt`, and the *entire* prompt is then POSIX
  single-quote escaped in `assembleCommand` before reaching `/bin/zsh -lc`.
  A transcript of `'; rm -rf / #` becomes inert literal text inside the quoted
  word. The `'` → `'\''` escape is correct.
- **Token handling:** Correct. The token is passed only via
  `Process.environment` (`CLIRunner` `environment:` param), never in the command
  string (so it cannot leak via `ps`), and is never logged. `--allowedTools` is
  scoped to `mcp__github__issue_write Read Grep Glob`; no `bypassPermissions` /
  `dangerously-skip-permissions`. Verified `claude --allowedTools` accepts the
  space-separated form, so the unquoted multi-token argument is correct.
- **Tempfile cleanup:** Correct on all paths. The `defer` is registered
  immediately after a successful `write`, and `write(atomically:)` leaves no
  destination file if it throws, so no orphan is possible. The
  token-failure path returns before the tempfile is even created (test-verified).
- **Error mapping:** Complete. Every `IssueFilingError` and `IssueParseError`
  case is mapped; the `parseFailed` wording was correctly de-risked to avoid
  implying a false success.

The one genuine correctness defect is in the `AppState` state machine: a
push-to-talk re-press during the (up-to-300 s) `.transcribing`/`.filing` window
is not blocked and corrupts the state machine. The remaining findings are
quality/UX issues and parser edge cases.

## Critical Issues

### CR-01: `startRecording()` re-entry during `.transcribing` / `.filing` corrupts the state machine

**File:** `Sources/MakeAnIssue/AppState.swift:167` (also the key-down handler at `:131-136`)
**Issue:**
`startRecording()` guards only against `.recording`:

```swift
guard captureState != .recording else { return }
```

It therefore *permits* a fresh recording to start while the app is in
`.transcribing` or `.filing`. The `.filing` state can last up to the 300 s
CLI timeout. The keyboard handler at `:131` has the same `!= .recording`
guard, so a real push-to-talk press during filing reaches `startRecording()`.

Concrete failure sequence (user presses PTT again while an issue is being filed):
1. `captureState` is `.filing`; `startRecording()` passes the guard.
2. `onStartRecording()` fires and `captureState` is overwritten to `.recording`
   — a new capture begins while the prior filing `Task` is still in flight.
3. The in-flight filing `Task` completes and runs `self.captureState = .idle`
   (success or error branch, `:262`/`:268`/`:274`), **clobbering** the active
   `.recording` state to `.idle`.
4. The user releases PTT → `stopRecording()` checks `captureState == .recording`
   → now false → returns without stopping. The recorder is left running with
   the UI showing `Idle`, and the captured audio is silently dropped.

The comment at `:166` justifies excluding `.finished` ("transient"), but
`.transcribing` and `.filing` are *not* transient and are unguarded.

**Fix:** Only allow a fresh start from `.idle`, and mirror the guard in the
key-down handler:

```swift
func startRecording() {
    // Block re-entry during transcription/filing, not just active recording.
    guard captureState == .idle else { return }
    ...
}
```

```swift
KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
    MainActor.assumeIsolated {
        guard let self, self.captureState == .idle else { return }
        self.startRecording()
    }
}
```

(Note: there is currently no test exercising a PTT press during `.filing`;
`testStartRecordingAfterFilingReturnsToIdleStartsNewRecording` only covers the
post-`.idle` case. Add a re-entry-during-filing test.)

## Warnings

### WR-01: CLI Command UI field is persisted but never wired into `IssueFilingRunner`

**File:** `Sources/MakeAnIssue/MenuView.swift:58-63`, `Sources/MakeAnIssue/AppState.swift:102-104`
**Issue:**
`MenuView` exposes a "CLI Command" `@AppStorage(AppState.cliCommandKey)` field and
comments that it "lets the user point this at a different AI CLI without
rebuilding the app" (`:59-60`). But the default `onRunIssueFiling` closure
hardcodes `config: .claudeGitHub` (`:103`) and never reads
`UserDefaults.standard.string(forKey: AppState.cliCommandKey)`. The stored value
has **no effect** on filing — unlike `asrCommandKey`, which *is* read at `:99`.
The user can edit the field and observe nothing change, contradicting the inline
comment and the PROVIDER-01 "point the seam" intent in the plan/PATTERNS docs.

This is either a missing wire (bug) or a forward-compat placeholder. If
intentional for v1, the misleading comment should be corrected; if not, the
value should be threaded through, e.g.:

**Fix:** Read the stored command in the default closure and build a config from it:

```swift
onRunIssueFiling: @escaping (String, RepoBinding) async throws -> IssueFilingResult = { transcript, repo in
    let cli = UserDefaults.standard.string(forKey: AppState.cliCommandKey) ?? "claude"
    var config = IssueFilingConfig.claudeGitHub
    config = IssueFilingConfig(cliCommand: cli, /* …carry other fields… */)
    return try await IssueFilingRunner.file(transcript: transcript, repo: repo, config: config, ownerRepo: nil)
}
```

…or, if v1 truly ignores it, change the MenuView comment to say the field is a
non-functional preview and not yet consumed.

### WR-02: `statusText` is never updated on successful filing

**File:** `Sources/MakeAnIssue/AppState.swift:254-263`
**Issue:**
On a successful file, `beginFiling` speaks "created issue #N" and sets
`captureState = .idle`, but it never updates `statusText`. `MenuView` renders
`LabeledContent("Status", value: appState.statusText)` (`MenuView.swift:20`), so
after a successful filing the Status row still shows whatever it was last — the
initial `"Ready"` or a stale prior error message. The only persistent visual
confirmation of success (the issue number/URL) is the transient spoken phrase;
nothing in the always-visible status reflects the result. By contrast every
*failure* path sets `statusText`. Users who miss the TTS get no status feedback.

**Fix:** Set a success status alongside the spoken confirmation:

```swift
let text = "created issue #\(result.number)"
self.statusText = "Filed issue #\(result.number)"
if let onSpeak = self.onSpeak { onSpeak(text) } else { self.speak(text) }
self.captureState = .idle
```

### WR-03: `structuredURLRegex` silently fails on issue URLs with a trailing path segment

**File:** `Sources/MakeAnIssue/IssueResultParser.swift:38-44`
**Issue:**
The structured pattern requires the closing quote to immediately follow the
issue number:

```
"(?:url|html_url)"\s*:\s*"(https?://github\.com/[^"]+/issues/(\d+))"
```

If a tool_result returns a URL with anything after the number (e.g.
`.../issues/89/comments` or `.../issues/89#issuecomment-…`), the trailing `"`
no longer follows `(\d+)`, the structured match fails, and parsing silently
falls back to the prose path. If the prose path also lacks a bare URL, the whole
file is reported as `parseFailed` even though the issue was created. This is a
silent correctness gap that depends on the exact shape of the MCP response.

**Fix:** Allow an optional trailing path/fragment after the number and stop the
number capture at a path boundary:

```swift
#""(?:url|html_url)"\s*:\s*"(https?://github\.com/[^"]+/issues/(\d+))(?:[/#?][^"]*)?""#
```

(Capture group 1 is still the canonical `.../issues/N` URL; group 2 is the
number.)

### WR-04: Multiple `tool_result` blocks use last-wins, which can capture the wrong issue number

**File:** `Sources/MakeAnIssue/IssueResultParser.swift:103-105`
**Issue:**
`fromToolResult` is overwritten on every matching `tool_result` block, so the
**last** issue-bearing tool_result wins:

```swift
if let result = extractFromStructuredText(text) {
    fromToolResult = result   // last write wins
}
```

The prompt instructs the model to investigate the repo before creating the
issue. If the model performs any post-create read or verification call whose
result also contains an `/issues/N` URL (e.g. listing or re-fetching the issue,
or referencing a *related* issue it found during investigation), the parser
would report that later/other number instead of the one it just created.
The "structured wins over prose" test exists, but there is no test for *two*
tool_results in a single stream.

**Fix:** Prefer the first successful structured extraction (the create call is
the first write-bearing tool_result), or constrain extraction to the tool whose
name matches `config.mcpToolName`. Minimal change:

```swift
if fromToolResult == nil, let result = extractFromStructuredText(text) {
    fromToolResult = result   // first-wins
}
```

Add a two-tool_result regression test to lock the chosen semantics.

## Info

### IN-01: Dead scaffolding in `testFilingEntersFilingState`

**File:** `Tests/MakeAnIssueTests/AppStateTests.swift:600-604, 629`
**Issue:**
`let filingStarted = CheckedContinuation<Void, Never>.self` is created only to be
immediately suppressed with `_ = filingStarted` (`:600-601`), and a
`DispatchSemaphore` is created and `sem.signal()`-ed (`:604`, `:629`) but never
`wait()`-ed. The test actually synchronizes via `Task.sleep`. This is leftover
scaffolding that adds noise and suggests an abandoned synchronization approach.
**Fix:** Remove `filingStarted`, the `_ = filingStarted` line, and the `sem`
declaration/`sem.signal()`; rely on the existing `Task.sleep` polling.

### IN-02: `IssueParseError.malformedOutput` is declared but never thrown

**File:** `Sources/MakeAnIssue/IssueResultParser.swift:19`
**Issue:**
The enum case `malformedOutput` is never constructed; malformed JSON lines are
silently skipped (`:72-76`) and an unparseable stream yields `.noIssueFound`.
It is handled in `IssueFilingRunner` (`:184`) only as a dead branch. (Already
acknowledged as a known follow-up in the phase context — recorded here for
completeness.)
**Fix:** Either remove the unused case or throw it when a line that *should* be
structured JSON fails to decode; keep the error surface honest.

---

_Reviewed: 2026-06-25_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: deep_

## Resolution

CR-01 fixed in commit `<will fill>`, regression test `testPushToTalkDuringFilingIsIgnored` added.
WR-01 (decorative CLI Command field), WR-02 (stale status on success), WR-03 (parser trailing-URL-segment),
WR-04 (multi tool_result last-wins), IN-01 (test scaffolding), IN-02 (dead malformedOutput case) — DEFERRED as tracked v1.x follow-ups.
