---
phase: 4
slug: voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
status: planned
nyquist_compliant: true
wave_0_complete: false
created: 2026-06-25
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: see `## Validation Architecture` in 04-RESEARCH.md (Test Framework, Phase Requirements → Test Map, Sampling Rate, Wave 0 Gaps). The planner lifts the per-task map from there; the executor checks boxes during Wave 0.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest (Swift Package) |
| **Config file** | Package.swift (existing) |
| **Quick run command** | `swift test --filter IssueResultParserTests` |
| **Full suite command** | `swift test` |
| **Estimated runtime** | ~10–30 seconds (unit suite); ~30s–2min for the 04-04 real-claude checkpoint |

---

## Sampling Rate

- **After every task commit:** Run the task's `--filter` command (pure unit, < 5s)
- **After every plan wave:** Run `swift test`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds for the unit suite

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | ISSUE-02 | T-04-02 / T-04-03 | Number parsed from url path (not id); permission_denials → failure | unit | `swift test --filter IssueResultParserTests` | ❌ W0 | ⬜ pending |
| 04-01-02 | 01 | 1 | PROVIDER-01 | T-04-06 | Scoped `--allowedTools` derived from config; codex/Jira deferred | unit | `swift test --filter IssueFilingConfigTests` | ❌ W0 | ⬜ pending |
| 04-01-03 | 01 | 1 | AUTH-01 | T-04-01 | Token passes via env, not the command string | unit | `swift test --filter CLIRunnerTests` | ✅ (extend) | ⬜ pending |
| 04-02-01 | 02 | 2 | ANALYZE-01 / ANALYZE-02 | T-04-04 / T-04-06 | Transcript shell-escaped; scoped grant; structured `stream-json --verbose`; no bypass flags | unit | `swift test --filter IssueFilingRunnerTests/testCommandAssembly` | ❌ W0 | ⬜ pending |
| 04-02-02 | 02 | 2 | ISSUE-01 / AUTH-01 | T-04-05 / T-04-07 / T-04-08 | cwd=repo; token via env; MCP tempfile deleted on every path; 300s timeout; one error type | unit | `swift test --filter IssueFilingRunnerTests` | ❌ W0 | ⬜ pending |
| 04-03-01 | 03 | 3 | FEEDBACK-01 | T-04-10 | Auto-enters .filing; success speaks human-facing number; failures status-only, reset to .idle | unit | `swift test --filter AppStateTests` | ✅ (extend) | ⬜ pending |
| 04-03-02 | 03 | 3 | PROVIDER-01 | — | `.filing` label exhausted; persisted CLI Command field | build | `swift build` | ✅ (extend) | ⬜ pending |
| 04-04-01 | 04 | 4 | (gate) | T-04-13 | Full suite green; runtime prerequisites present | integration | `swift test` | ✅ | ⬜ pending |
| 04-04-02 | 04 | 4 | ANALYZE-01/02, ISSUE-01/02, FEEDBACK-01 | T-04-12 / T-04-13 | Real issue filed via MCP; correct number spoken; no false success on failure | human-verify | (manual — see plan) | n/a | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Tests/MakeAnIssueTests/IssueResultParserTests.swift` — JSONL tool_result extraction, prose fallback, permission_denials gate (ISSUE-02)
- [ ] `Tests/MakeAnIssueTests/IssueFilingConfigTests.swift` — scoped allowedTools + issues-scoped MCP JSON (PROVIDER-01)
- [ ] `Tests/MakeAnIssueTests/IssueFilingRunnerTests.swift` — command assembly, prompt, escaping, token-failure path (ANALYZE-01/02, ISSUE-01)
- [ ] Inline JSONL fixtures modeled on spike 002 output (no file I/O) inside the parser tests
- Framework: XCTest already configured in Package.swift — no install needed.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real issue filed via AI CLI MCP against live GitHub | ISSUE-01, ANALYZE-01/02 | Requires Docker, an authenticated `gh`/`claude` session, and network; creates a real side effect | 04-04 checkpoint steps 1–6 |
| Audible "created issue #NUMBER" spoken via TTS | FEEDBACK-01 | Audio output cannot be asserted headlessly; the AppState seam is unit-tested but the actual utterance is heard | 04-04 checkpoint step 5 |
| No false success on failure (Docker down / signed out) | (negative) | External-failure injection + audio confirmation | 04-04 checkpoint step 7 |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies (04-04-02 is the one intentional human-verify gate)
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (three new test files listed above)
- [x] No watch-mode flags
- [x] Feedback latency < 30s for the unit suite
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-06-25
