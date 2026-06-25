# Open Research Questions

Questions surfaced during exploration that need deeper investigation before planning.

---

## SPIKE (gates Phase 4) — Non-interactive AI-CLI issue-filing via MCP

**Raised:** 2026-06-25 (`/gsd-explore`) · **Run via:** `/gsd-spike` · **Blocks:** merged Phase 4

Prove end-to-end, on this machine, that the app can shell out to the user's AI CLI and have it
**file a real issue via MCP, non-interactively**, returning a parseable issue URL — with no API
token held by the app.

Acceptance / sub-questions:

1. **Claude + GitHub (proven leg — confirm hands-on):** Does
   `claude -p "<prompt>" --output-format json --mcp-config <file> --allowedTools "mcp__github__create_issue"`
   actually create an issue and return a URL we can regex out? Confirm the GitHub **remote** MCP
   server (OAuth, no PAT) is what's wired.
2. **Codex (spike-gated):** Can `codex exec` execute an MCP write tool non-interactively at all, or
   is it blocked by the stdin-EOF auto-cancel bug (openai/codex #24135)? If only
   `--dangerously-bypass-approvals-and-sandbox` works, is that acceptable, or is codex deferred?
3. **Jira (spike-gated):** Can the Atlassian/Jira MCP create an issue non-interactively after a
   **one-time** OAuth grant persisted in the CLI's credential store — with NO API token? Or is it
   infeasible (interactive-only OAuth)?
4. **Output parsing:** How reliable is "reply with ONLY the issue URL on the last line" + regex
   across runs? Any structured-output flag that does better?
5. **Latency:** Measure real round-trip (model reasoning + repo read + MCP call) to size the
   spoken-confirmation UX.

Outcome should either green-light Phase 4 (and confirm which provider×destination combos are v1 vs
deferred) or send specific items back to v2. Context: `.planning/notes/v1-realign-bundled-whisper-ai-cli-mcp.md`.
