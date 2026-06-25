# Spike Manifest

## Idea

Prove the riskiest assumption in the make-an-issue v1 realignment (2026-06-25): that the user's
own AI coding CLI (`claude`/`codex`), invoked **non-interactively** in the bound repo, can draft
**and file** a tracker issue through its already-configured MCP server (GitHub or Atlassian/Jira)
— with no human approving the MCP tool-permission prompt — and emit the new issue number/URL in
a form the app can parse and speak back. This session proves the **claude + GitHub** path; the
`codex` + Jira path is deferred to a later spike.

## Requirements

Design decisions that emerged during spiking. Non-negotiable for the real build. Updated as
spikes progress.

- The app MUST pass an explicit, **scoped** tool grant to the AI CLI — `--allowedTools
  "mcp__<server>__<issue-tool>"` (least privilege), NOT `--permission-mode bypassPermissions`
  (which grants every tool incl. shell/file-write). [Spike 001]
- The app MUST invoke the CLI with `--output-format json` and inspect the `permission_denials`
  array to distinguish "tool not granted" failures from MCP/network errors. [Spike 001]
- Headless `claude -p` does NOT hang on an un-granted tool — it returns exit 0 with a denial. The
  app's failure handling can rely on a clean return, but MUST still treat a populated
  `permission_denials` as a failure (no issue was filed). [Spike 001]

## Spikes

| # | Name | Type | Validates | Verdict | Tags |
|---|------|------|-----------|---------|------|
| 001 | claude-headless-mcp-permission | standard | `claude -p` (no TTY) calls an MCP tool with no interactive approval | ✅ VALIDATED | claude, mcp, headless, permissions |
| 002 | claude-github-file-issue | standard | `claude -p` files a real GitHub issue via MCP; #number+URL parseable from output | PENDING | claude, github, mcp, e2e, parsing |

<sub>Deferred this session: 003 codex-jira-file-issue (no Jira/Atlassian MCP reachable — see /gsd-spike answers 2026-06-25).</sub>
