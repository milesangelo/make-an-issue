---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
verified: 2026-06-25T19:15:00Z
status: passed
score: 5/5 must-haves verified
behavior_unverified: 0
overrides_applied: 0
re_verification: false
---

# Phase 04: Voice AI CLI Drafts + Files Issue via MCP + Spoken Confirmation — Verification Report

**Phase Goal:** Hand the transcript to the user's AI coding CLI (claude) running in the bound repo; the CLI investigates the repo, drafts the issue, and files it through its own configured MCP server (GitHub). The app parses the created issue's number/URL from stdout and speaks "created issue #NUMBER". No gh API token held by the app — it rides the CLI's existing session.
**Verified:** 2026-06-25T19:15:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | The app invokes the configured AI CLI with the transcript and working directory = bound repo | ✓ VERIFIED | `IssueFilingRunner.file()` calls `CLIRunner().run(command:workingDirectory:repo.rootURL:environment:timeout:.seconds(300))` — cwd is set to `repo.rootURL` (IssueFilingRunner.swift:163). `AppState` default `onRunIssueFiling` closure calls `IssueFilingRunner.file(transcript:transcript, repo:repo, config:.claudeGitHub, ownerRepo:nil)` (AppState.swift:103). AppStateTests `testFilingSeamCalledWithTranscriptAndRepo` confirms transcript and repo are passed correctly. |
| 2 | A real issue is created through the CLI's MCP server (GitHub proven). The app holds no tokens; it rides the CLI's session. | ✓ VERIFIED (human-confirmed) | Human checkpoint PASSED: issues #90 and #91 filed in pulsedemon/netshooter (2026-06-26). Token is acquired via `gh auth token` fallback and passed via `Process.environment` only — never in the command string (IssueFilingRunner.swift:122–137, 164). `IssueFilingConfig.claudeGitHub` uses docker-based GitHub MCP server, no app-held credential. |
| 3 | The created issue number/URL is parsed from the CLI's stdout (URL-path regex, never the node id) | ✓ VERIFIED | `IssueResultParser` uses regex `"(?:url|html_url)"\s*:\s*"(https?://github\.com/[^"]+/issues/(\d+))"` — number is capture group 2 (path digit), not the `id` field. Prose fallback also uses `/issues/(\d+)` path capture. `testStructuredToolResultReturnsNumberFromURLPath` asserts `result.number == 89` (not the node-id string in `id` field). Human checkpoint confirmed small human-facing numbers were spoken. |
| 4 | The app speaks "created issue #NUMBER" via native text-to-speech | ✓ VERIFIED (human-confirmed) | `AppState.speak()` builds `AVSpeechUtterance` and calls stored `speechSynthesizer.speak(utterance)` (AppState.swift:284–287). `beginFiling()` builds text as `"created issue #\(result.number)"` and calls the seam (AppState.swift:256). `AVSpeechSynthesizer` is a stored property (not a local) preventing dealloc before speaking completes. `testSuccessfulFilingSpeaksIssueNumber` asserts spoken text contains "42". Human checkpoint confirmed correct audio spoken for issues #90 and #91. |
| 5 | Backend is provider-agnostic via a configurable command seam; codex + Jira explicitly documented as deferred | ✓ VERIFIED | `IssueFilingConfig` struct provides the provider seam with fields `cliCommand`, `mcpServerName`, `mcpToolName`, `tokenEnvKey`, `tokenCommand`, `mcpServerJSON`. `claudeGitHub` is the static default. Doc comment explicitly states: "codex + GitHub: codex exec non-interactive MCP writes are broken upstream... Atlassian/Jira: Zero-token non-interactive Jira write may require interactive OAuth. Deferred per REQUIREMENTS.md PROVIDER-01." MenuView exposes `@AppStorage(AppState.cliCommandKey)` CLI Command field defaulting to `"claude"` (MenuView.swift:11, 61–63). |

**Score:** 5/5 truths verified (0 present, behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Sources/MakeAnIssue/IssueResultParser.swift` | JSONL tool_result walker + prose-regex fallback; IssueFilingResult, IssueParseError | ✓ VERIFIED | Exists, substantive (147 lines), wired — called by IssueFilingRunner.swift:178 |
| `Sources/MakeAnIssue/IssueFilingConfig.swift` | Provider seam value type + IssueFilingError; claudeGitHub static default | ✓ VERIFIED | Exists, substantive (109 lines), wired — used by IssueFilingRunner.swift throughout |
| `Sources/MakeAnIssue/IssueFilingRunner.swift` | file(transcript:repo:config:ownerRepo:) orchestration | ✓ VERIFIED | Exists, substantive (190 lines), wired — called by AppState.swift:103 default closure |
| `Sources/MakeAnIssue/CLIRunner.swift` | environment: [String:String]? parameter on run() | ✓ VERIFIED | Parameter exists at line 78; merge logic at lines 88–92; all existing call sites unaffected by nil default |
| `Sources/MakeAnIssue/AppState.swift` | .filing CaptureState, onRunIssueFiling seam, AVSpeechSynthesizer, speak(), beginFiling(), cliCommandKey | ✓ VERIFIED | All symbols present and wired: `case filing` (line 13), `onRunIssueFiling` seam (line 47), `speechSynthesizer` stored property (line 50), `speak()` method (line 284), `beginFiling()` (line 239), `cliCommandKey` (line 25) |
| `Sources/MakeAnIssue/MenuView.swift` | .filing label "Filing issue…", CLI Command @AppStorage field | ✓ VERIFIED | `case .filing: return "Filing issue…"` (line 85); `@AppStorage(AppState.cliCommandKey) var cliCommand: String = "claude"` (line 11); `LabeledContent("CLI Command")` (line 61) |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `AppState.swift` | `IssueFilingRunner.swift` | Default `onRunIssueFiling` closure calls `IssueFilingRunner.file(transcript:repo:config:.claudeGitHub:ownerRepo:nil)` | ✓ WIRED | AppState.swift:102–104 |
| `AppState.swift` | `AVSpeechSynthesizer` | Stored `speechSynthesizer` property; `speak(_:)` method calls `speechSynthesizer.speak(utterance)` | ✓ WIRED | AppState.swift:50, 284–287 |
| `IssueFilingRunner.swift` | `CLIRunner.swift` | `CLIRunner().run(command:workingDirectory:repo.rootURL:environment:[tokenEnvKey:token]:timeout:.seconds(300))` | ✓ WIRED | IssueFilingRunner.swift:161–166 |
| `IssueFilingRunner.swift` | `IssueResultParser.swift` | `IssueResultParser.parse(stdout:)` called on `.success` stdout | ✓ WIRED | IssueFilingRunner.swift:178 |
| `IssueFilingRunner.swift` | Issue URL path regex | Structured regex extracts `(\d+)` from `/issues/(\d+)` path, not `id` field | ✓ WIRED | IssueResultParser.swift:42 — capture group 2 is the path digit |

### Data-Flow Trace (Level 4)

Not applicable — no UI components rendering dynamic data from an API/store. The artifacts are a processing pipeline (transcript → CLI invocation → parsed result → spoken text), not a data-fetching renderer. The pipeline produces real side effects confirmed by human verification.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| 111-test suite green | `swift test` | 111 tests, 0 failures | ✓ PASS |
| IssueResultParser extracts number from URL path (not id) | `swift test --filter IssueResultParserTests/testStructuredToolResultReturnsNumberFromURLPath` | PASS — result.number == 89 | ✓ PASS (confirmed in suite run) |
| permission_denials gate throws before returning result | `swift test --filter IssueResultParserTests/testPermissionDeniedDetected` | PASS | ✓ PASS (confirmed in suite run) |
| parseFailed message does not imply issue was filed | `swift test --filter AppStateTests/testParseFailedStatusMessageIsNotMisleading` | PASS — "Couldn't confirm an issue was filed — check GitHub (is Docker running?)" | ✓ PASS (confirmed in suite run) |
| Filing seam called with transcript + repo | `swift test --filter AppStateTests/testFilingSeamCalledWithTranscriptAndRepo` | PASS | ✓ PASS (confirmed in suite run) |
| No tempfile left after token failure | `swift test --filter IssueFilingRunnerTests/testFileWithFailingTokenCommandLeavesNoTempFile` | PASS | ✓ PASS (confirmed in suite run) |
| Full end-to-end: real GitHub issues filed, correct number spoken | Human checkpoint (Wave 4) | Issues #90 and #91 filed in pulsedemon/netshooter; correct small human-facing numbers spoken; negative-check (Docker stopped) showed no false success | ✓ PASS (human-confirmed, non-repeatable integration test) |

### Probe Execution

No probe scripts declared or present for this phase. Step 7c: SKIPPED (no probe-*.sh files).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| ANALYZE-01 | 04-02, 04-04 | App invokes user's AI coding CLI with cwd = bound repo | ✓ SATISFIED | `IssueFilingRunner.file()` sets `workingDirectory: repo.rootURL` in `CLIRunner().run()` call |
| ANALYZE-02 | 04-02, 04-04 | AI CLI drafts the issue from transcript and repo context | ✓ SATISFIED | `buildPrompt()` instructs the model to "Briefly investigate the repo" and file the issue; proven by human-verified filing of real issues with accurate bodies |
| ISSUE-01 | 04-02, 04-04 | AI CLI files through its own MCP server; app holds no gh/API token | ✓ SATISFIED | Token acquired via env-var-first / `gh auth token`, passed via `Process.environment` only; `IssueFilingConfig.claudeGitHub` uses docker GitHub MCP server |
| ISSUE-02 | 04-01, 04-04 | App parses issue number/URL from CLI stdout (URL-path regex, not node id) | ✓ SATISFIED | `IssueResultParser` regex extracts number from `/issues/(\d+)` path; human checkpoint confirmed small human-facing numbers spoken |
| FEEDBACK-01 | 04-03, 04-04 | App speaks "created issue #NUMBER" via native macOS TTS | ✓ SATISFIED | `AppState.speak()` + stored `AVSpeechSynthesizer`; human checkpoint confirmed audio spoken correctly |
| PROVIDER-01 | 04-01, 04-03 | AI backend provider-agnostic via configurable command seam; codex+Jira documented deferred | ✓ SATISFIED | `IssueFilingConfig` struct is the provider seam; doc comment documents codex/Jira as deferred; MenuView CLI Command field defaults to `"claude"` |
| AUTH-01 | 04-02, 04-04 | App never stores/transmits credentials; rides pre-authenticated MCP session | ✓ SATISFIED | Token only in `Process.environment`, never in command string; no token persistence; comment "Never log the token value. (T-04-05)" at IssueFilingRunner.swift:139 |

All 7 phase-4 requirements verified as SATISFIED. No orphaned requirements.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `Sources/MakeAnIssue/MenuView.swift` | 53 | `// The {wav} placeholder...` — comment contains "placeholder" | ℹ️ Info | Not a code stub — this is a doc comment explaining the `{wav}` substitution token in the ASR command field. Not a phase-04 concern; pre-existing from Phase 3. |

No BLOCKER anti-patterns found. No TBD/FIXME/XXX markers in any phase-4 modified files.

**Known dead enum case (documented, not a blocker):** `IssueParseError.malformedOutput` is declared but never thrown anywhere in the codebase. The 04-04-SUMMARY.md documents this explicitly: "IssueParseError.malformedOutput is a declared-but-never-thrown dead enum case (known minor follow-up; not a phase-goal gap)." This does not affect any success criterion.

### Human Verification Required

None. All human-verification items were completed at the Wave 4 (04-04) checkpoint:

- Real issues #90 and #91 filed end-to-end in pulsedemon/netshooter via voice → whisper → claude+GitHub MCP.
- Spoken numbers were the correct small human-facing URL-path numbers (not node-ids).
- Negative check passed: Docker stopped → no false success spoken, status error shown, returns to Idle.
- Full suite: 111 tests, 0 failures.

The human checkpoint is documented in `04-04-SUMMARY.md` with issue URLs, timestamps, filing latency, and negative-check result.

### Gaps Summary

No gaps. All 5 observable truths verified. All 7 requirements satisfied. All 6 required artifacts exist, are substantive, and are wired. All key links confirmed. Full test suite (111 tests) passes. Human checkpoint confirmed end-to-end behavior including the integration criteria that cannot be re-run (real GitHub issues filed, correct number spoken).

---

_Verified: 2026-06-25T19:15:00Z_
_Verifier: Claude (gsd-verifier)_
