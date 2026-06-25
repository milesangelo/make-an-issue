---
phase: 04-voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
plan: "01"
subsystem: issue-filing-foundation
status: complete
tags: [swift, parsing, configuration, cli-runner, mcp, tdd]
completed_date: "2026-06-25"
duration: "~8 minutes"

dependency_graph:
  requires: []
  provides:
    - IssueFilingResult
    - IssueParseError
    - IssueResultParser
    - IssueFilingConfig
    - IssueFilingError
    - CLIRunner.run(environment:)
  affects:
    - 04-02-PLAN.md

tech_stack:
  added: []
  patterns:
    - JSONL line-by-line JSONSerialization walk (NSRegularExpression, static-let)
    - Typed Error enum style matching TranscriberError
    - Equatable value-type provider seam
    - Process.environment merge over ProcessInfo.processInfo.environment

key_files:
  created:
    - Sources/MakeAnIssue/IssueResultParser.swift
    - Sources/MakeAnIssue/IssueFilingConfig.swift
    - Tests/MakeAnIssueTests/IssueResultParserTests.swift
    - Tests/MakeAnIssueTests/IssueFilingConfigTests.swift
  modified:
    - Sources/MakeAnIssue/CLIRunner.swift
    - Tests/MakeAnIssueTests/CLIRunnerTests.swift

decisions:
  - IssueParseError conforms to Equatable (matching TranscriberError style) for direct assertion in XCTestCase
  - structuredURLRegex matches both "url" and "html_url" fields for completeness (spike 002 reference parser does the same)
  - mcpServerJSON stored as a raw JSON string in IssueFilingConfig so claudeGitHub is self-contained with no Foundation import needed
  - CLIRunner environment parameter placed between workingDirectory and timeout (not at end) to match Plan 04-01 interface spec and keep token-passthrough intent co-located with working-directory intent

requirements:
  - ISSUE-02
  - PROVIDER-01
---

# Phase 04 Plan 01: Foundation Pieces Summary

Three independent, dependency-free foundation pieces for AI-CLI issue filing: JSONL parser that extracts the issue number from the url path (never the id field), a provider-agnostic config seam with a validated claude+GitHub default, and an optional environment passthrough parameter on CLIRunner.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | IssueResultParser — JSONL walk + prose fallback + permission_denials gate | 156acb9 | IssueResultParser.swift, IssueResultParserTests.swift |
| 2 | IssueFilingConfig — provider seam + IssueFilingError + claudeGitHub default | 09f4761 | IssueFilingConfig.swift, IssueFilingConfigTests.swift |
| 3 | CLIRunner.run — optional environment passthrough parameter | d6af2b6 | CLIRunner.swift, CLIRunnerTests.swift |

## Verification Results

- `swift test --filter IssueResultParserTests`: 9 tests, 0 failures
- `swift test --filter IssueFilingConfigTests`: 13 tests, 0 failures
- `swift test --filter CLIRunnerTests`: 8 tests, 0 failures (6 pre-existing + 2 new)
- `swift test` (full suite): 83 tests, 0 failures
- `swift build`: Build complete with 0 warnings

## Artifacts Produced

### IssueResultParser.swift
- `struct IssueFilingResult { let number: Int; let url: String }` — parse output contract
- `enum IssueParseError: Error, Equatable` — `permissionDenied([String])`, `noIssueFound`, `malformedOutput`
- `struct IssueResultParser` — `static func parse(stdout: String) throws -> IssueFilingResult`
- Algorithm: split on `\n`, JSON-decode each line, walk `assistant` content for `tool_result` blocks, fall back to prose regex on `result` event text
- Issue number extracted from `url` path `/issues/(\d+)` ONLY — never from `id` field (T-04-03)
- `permission_denials` non-empty triggers `permissionDenied` throw before any url check (T-04-02)

### IssueFilingConfig.swift
- `struct IssueFilingConfig: Equatable` — 6 fields: `cliCommand`, `mcpServerName`, `mcpToolName`, `tokenEnvKey`, `tokenCommand`, `mcpServerJSON`
- `var allowedToolsArgument: String` — `"mcp__<server>__<tool> Read Grep Glob"` (least privilege, never bypassPermissions)
- `var mcpConfigJSON: String` — `{"mcpServers":{"<server>":<json>}}` tempfile body
- `static let claudeGitHub` — `claude` + `ghcr.io/github/github-mcp-server` via Docker, `GITHUB_TOOLSETS=issues`, `gh auth token`
- `enum IssueFilingError: Error, Equatable` — 5 cases covering all failure modes
- codex/Jira documented deferred in doc comment per PROVIDER-01

### CLIRunner.swift (modified)
- Added `environment: [String: String]? = nil` between `workingDirectory` and `timeout`
- When non-nil: starts from `ProcessInfo.processInfo.environment`, overlays caller keys, assigns to `process.environment`
- Default `nil` keeps all existing call sites (Transcriber, existing tests) unchanged
- Token passes via env, not command string — keeps it out of `ps` output (T-04-01, Pitfall 2)

## Deviations from Plan

None — plan executed exactly as written.

## Threat Mitigations Implemented

| Threat ID | Mitigation |
|-----------|-----------|
| T-04-01 | `CLIRunner.environment` merges token into `Process.environment`, not the `-lc` command string |
| T-04-02 | Parser gates on `permission_denials` before returning any result; non-empty = throw |
| T-04-03 | Parser extracts number from `/issues/(\d+)` url path only; `id` field is never read |

## Known Stubs

None — all new symbols are complete implementations with no placeholder data or TODO paths.

## Threat Flags

None — no new network endpoints, auth paths, or file access patterns introduced beyond what the plan specified.

## Self-Check: PASSED

Files exist:
- FOUND: Sources/MakeAnIssue/IssueResultParser.swift
- FOUND: Sources/MakeAnIssue/IssueFilingConfig.swift
- FOUND: Tests/MakeAnIssueTests/IssueResultParserTests.swift
- FOUND: Tests/MakeAnIssueTests/IssueFilingConfigTests.swift

Commits exist:
- FOUND: 156acb9 (IssueResultParser)
- FOUND: 09f4761 (IssueFilingConfig)
- FOUND: d6af2b6 (CLIRunner environment param)
