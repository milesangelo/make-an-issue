# Spike Wrap-Up Summary

**Date:** 2026-06-25
**Spikes processed:** 2
**Feature areas:** Headless CLI invocation, GitHub issue filing & parsing
**Skill output:** `./.claude/skills/spike-findings-make-an-issue/`

## Processed Spikes

| # | Name | Type | Verdict | Feature Area |
|---|------|------|---------|--------------|
| 001 | claude-headless-mcp-permission | standard | ✅ VALIDATED | Headless CLI invocation |
| 002 | claude-github-file-issue | standard | ✅ VALIDATED | GitHub issue filing & parsing |

## Key Findings

- **The idea-killer risk is dead.** A scoped `--allowedTools "mcp__<server>__<tool>"` grant lets
  headless `claude -p` invoke MCP tools with no human in the loop, no TTY, no hang. Use scoped
  grants — never `bypassPermissions` — in the app path.
- **Un-granted tools auto-deny, they don't freeze.** Default mode returns exit 0 with the tool in
  `permission_denials`. The app must inspect that array, not trust the exit code.
- **End-to-end proven.** `claude -p` run with cwd = the bound repo investigated real code, filed a
  real GitHub issue (#89) via the official GitHub MCP (`issue_write`, `method=create`) in ~30s.
- 🔴 **Parse landmine:** the `issue_write` result is `{id, url}` with no `number` field. `id` is
  GitHub's internal node id; the human-facing number lives **only** in the url path (`/issues/<N>`).
  Parse the url, never the id. Prefer structured `stream-json` tool_result, fall back to prose regex.
- 🟡 **Product tension flagged:** the CLI corrects false premises and may file an issue that diverges
  from the literal transcript, while v1 files automatically with no review screen. Accuracy-vs-fidelity
  must be an explicit v1 decision or get a lightweight confirm step. (Carry into discuss/plan.)
- **Hygiene:** scope the MCP to `GITHUB_TOOLSETS=issues`, pass the token via Docker `-e` passthrough
  sourced from `gh auth token`, never written to a committed file.

## Deferred

- 003 codex-jira-file-issue — no Jira/Atlassian MCP reachable this session. The `codex` + Jira path
  remains unproven.
