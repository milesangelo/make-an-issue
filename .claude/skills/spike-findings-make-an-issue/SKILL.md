---
name: spike-findings-make-an-issue
description: Implementation blueprint from spike experiments. Requirements, proven patterns, and verified knowledge for building make-an-issue. Auto-loaded during implementation work.
---

<context>
## Project: make-an-issue

make-an-issue turns a developer's spoken thought into a tracker issue by shelling out to the
user's own AI coding CLI (`claude`/`codex`), invoked **non-interactively** in the bound repo, so
the CLI investigates the real code and files an issue through its already-configured MCP server
(GitHub proven; Atlassian/Jira deferred) — with no human approving the MCP tool-permission
prompt — then emits the new issue number/URL for the app to parse and speak back. v1 is a
Swift/macOS app with bundled whisper for voice → text.

Spike sessions wrapped: 2026-06-25
</context>

<requirements>
## Requirements

Non-negotiable design decisions that emerged during spiking. Every feature area reference honors these.

- The app MUST pass an explicit, **scoped** tool grant to the AI CLI — `--allowedTools
  "mcp__<server>__<issue-tool>"` (least privilege), NOT `--permission-mode bypassPermissions`
  (which grants every tool incl. shell/file-write). [Spike 001]
- The app MUST invoke the CLI with structured output (`--output-format json`/`stream-json`) and
  inspect the `permission_denials` array to distinguish "tool not granted" failures from
  MCP/network errors. [Spike 001]
- Headless `claude -p` does NOT hang on an un-granted tool — it returns exit 0 with a denial. The
  app MUST still treat a populated `permission_denials` as a failure (no issue was filed). [Spike 001]
- The app MUST run the AI CLI with **cwd = the bound repo** so it can investigate the real code
  before drafting. [Spike 002]
- 🔴 The app MUST parse the new issue number from the **`url`** in the GitHub MCP `issue_write`
  result (`.../issues/<N>`), NEVER from the `id` field — `id` is GitHub's internal node id, not the
  issue number. Prefer the structured `stream-json` tool_result; fall back to prose-text regex. [Spike 002]
- 🟡 v1 files automatically with no review screen, BUT the CLI investigates the repo and may file
  an issue that diverges from the literal transcript (it corrects false premises). This accuracy-vs-
  fidelity tension must be an explicit, accepted v1 decision — or v1 needs a lightweight confirm
  step. [Spike 002 — flag for discuss/plan]
- The app should scope the MCP server to the minimal toolset (`GITHUB_TOOLSETS=issues`) and pass
  the token via env passthrough, never writing it to a config file. [Spike 002]
</requirements>

<findings_index>
## Feature Areas

| Area | Reference | Key Finding |
|------|-----------|-------------|
| Headless CLI invocation | references/headless-cli-invocation.md | Scoped `--allowedTools` lets `claude -p` call MCP tools with no human; un-granted tools auto-deny (exit 0), they don't hang. |
| GitHub issue filing & parsing | references/github-issue-filing.md | `issue_write method=create` files the issue; the issue number lives ONLY in the result `url`, never the `id` field. |

## Source Files

Original spike source files are preserved in `sources/` for complete reference.
</findings_index>

<metadata>
## Processed Spikes

- 001-claude-headless-mcp-permission
- 002-claude-github-file-issue
</metadata>
