---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
plan: "02"
subsystem: issue-filing-runner
status: complete
tags: [swift, cli, mcp, shell-escaping, subprocess, token-passthrough, security]
completed_date: "2026-06-25"
duration: "~2 minutes"

dependency_graph:
  requires:
    - IssueFilingConfig
    - IssueFilingError
    - IssueResultParser
    - IssueFilingResult
    - IssueParseError
    - CLIRunner.run(workingDirectory:environment:timeout:)
  provides:
    - IssueFilingRunner
    - IssueFilingRunner.shellEscape(_:)
    - IssueFilingRunner.buildPrompt(transcript:ownerRepo:config:)
    - IssueFilingRunner.assembleCommand(prompt:mcpConfigPath:config:)
    - IssueFilingRunner.file(transcript:repo:config:ownerRepo:)
  affects:
    - 04-03-PLAN.md

tech_stack:
  added: []
  patterns:
    - POSIX single-quote shell escaping (reused from Transcriber.prepare)
    - Per-invocation MCP tempfile with defer-cleanup on every exit path
    - Env-var-first token acquisition (gh fallback, AUTH-01)
    - CLIRunner.run with cwd=repo.rootURL and token in environment (T-04-05)
    - IssueParseError→IssueFilingError translation (callers see one error type)

key_files:
  created:
    - Sources/MakeAnIssue/IssueFilingRunner.swift
    - Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift
  modified: []

decisions:
  - ownerRepo is optional in both buildPrompt and file() — nil means "the repository in the current working directory" (v1 Open Q1 assumption; model infers owner/repo from cwd .git/config)
  - shellEscape is a public static method on IssueFilingRunner (not private) so tests can assert escaping behavior directly without going through assembleCommand
  - IssueParseError is caught and rethrown as IssueFilingError in file() so all callers of IssueFilingRunner see a single error type (IssueFilingError) with no IssueParseError leakage
  - tempfile is written AFTER token acquisition succeeds — token failure leaves no tempfile (verified by test)

requirements:
  - ANALYZE-01
  - ANALYZE-02
  - ISSUE-01
  - AUTH-01
---

# Phase 04 Plan 02: IssueFilingRunner Summary

`IssueFilingRunner` orchestration layer: POSIX-escaped transcript embedded in a scoped `claude -p` command, env-var-first GitHub token passed via `Process.environment`, per-invocation MCP config tempfile with defer-cleanup, and CLIRunner invoked with `cwd=repo.rootURL` + 300s timeout.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | buildPrompt + shellEscape + assembleCommand (pure, testable) | 8047e56 | IssueFilingRunner.swift, IssueFilingRunnerTests.swift |
| 2 | file() — token acquire, MCP tempfile, CLIRunner call, parse + error mapping | 8047e56 | IssueFilingRunner.swift, IssueFilingRunnerTests.swift |

## Verification Results

- `swift test --filter IssueFilingRunnerTests/testCommandAssembly`: 7 tests, 0 failures
- `swift test --filter IssueFilingRunnerTests`: 19 tests, 0 failures
- `swift test` (full suite): 102 tests, 0 failures
- `swift build`: Build complete

## Artifacts Produced

### IssueFilingRunner.swift

- `static func shellEscape(_ raw: String) -> String` — POSIX single-quote escape; identical algorithm to `Transcriber.prepare`; handles `'` → `'\''`
- `static func buildPrompt(transcript: String, ownerRepo: String?, config: IssueFilingConfig) -> String` — embeds transcript verbatim, instructs `issue_write` tool with `method=create`, requires "Issue URL: …" on the last line for prose fallback, instructs model to file directly (no confirmation gate per `accepted_v1_behavior`)
- `static func assembleCommand(prompt: String, mcpConfigPath: String, config: IssueFilingConfig) -> String` — produces single `-lc` command: `claude -p <escaped-prompt> --mcp-config <escaped-abs-path> --strict-mcp-config --allowedTools mcp__github__issue_write Read Grep Glob --output-format stream-json --verbose`; never includes `bypassPermissions` or `dangerously-skip`
- `static func file(transcript:repo:config:ownerRepo:) async throws -> IssueFilingResult` — full orchestration: env-var-first token → CLIRunner gh fallback → tempfile write → assembleCommand → CLIRunner.run(cwd=repo.rootURL, env=[token], timeout=300s) → IssueResultParser.parse → IssueFilingError mapping

### IssueFilingRunnerTests.swift

19 unit tests covering:
- `buildPrompt`: transcript embedded verbatim; contains `issue_write`, `method=create`, `Issue URL:`; nil ownerRepo uses "current working directory"; ownerRepo embeds "acme/widget"; "Do not ask for confirmation" present
- `shellEscape`: wraps in single quotes; `'` → `'\''`; dollar/backtick inert
- `assembleCommand`: `--strict-mcp-config`, `--output-format stream-json`, `--verbose`, `--allowedTools mcp__github__issue_write Read Grep Glob`, `--mcp-config <path>`; no `bypassPermissions`; single-quote escaping verified structurally
- `file()` error paths: `tokenCommand: "false"` → throws `.tokenAcquisitionFailed`; no `make-an-issue-mcp-*` tempfile left behind after token failure

## Threat Mitigations Implemented

| Threat ID | Mitigation |
|-----------|-----------|
| T-04-04 | POSIX single-quote escape (`shellEscape`) applied to transcript and MCP config path before they enter the command string |
| T-04-05 | GitHub PAT passed via `[config.tokenEnvKey: token]` in `CLIRunner.run` environment parameter; never in the command string; never logged |
| T-04-06 | Scoped `--allowedTools config.allowedToolsArgument` only; absence of `bypassPermissions`/`dangerously-skip` asserted in tests |
| T-04-07 | MCP config written to `temporaryDirectory` with UUID suffix; `defer { try? FileManager.default.removeItem(at:) }` on every exit path |
| T-04-08 | `timeout: .seconds(300)` passed to `CLIRunner.run` — process terminated and `.timeout` → `IssueFilingError.timeout` |

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — all code paths are complete. The real-claude happy path (end-to-end filing) is explicitly marked for human verification in plan 04-04 and is not a stub in this plan.

## Threat Flags

None — no new network endpoints, auth paths, or file access patterns beyond what the plan's threat model specified.

## Self-Check: PASSED

Files exist:
- FOUND: Sources/MakeAnIssue/IssueFilingRunner.swift
- FOUND: Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift

Commits exist:
- FOUND: 8047e56 (IssueFilingRunner — all tasks)
