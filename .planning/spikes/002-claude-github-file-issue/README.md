---
spike: 002
name: claude-github-file-issue
type: standard
validates: "Given a repo + transcript and a working GitHub MCP, when `claude -p` runs headless in the repo, then it investigates, files a real GitHub issue via MCP, and stdout yields a parseable #number + URL"
verdict: VALIDATED
related: [001]
tags: [claude, github, mcp, e2e, parsing]
---

# Spike 002: claude-github-file-issue

## What This Validates

The full make-an-issue happy path, headless and non-interactive: run `claude -p` **inside the
bound repo** (cwd = the git repo), hand it a voice transcript, and have it investigate the repo,
draft an issue, and **actually file it** in GitHub via the user's MCP — then parse the new issue
`#number` + URL from the CLI output so the app can speak "created issue #89".

Builds directly on Spike 001 (which proved the headless MCP permission mechanic in isolation).
002 adds the three things 001 deliberately left out: a real GitHub MCP server, a real issue
creation side effect, and output parsing.

## Research

- **GitHub MCP server** (`claude mcp list` showed the pre-installed remote `plugin:github:github`
  was **Failed to connect** with a malformed auth header — unusable). Stood up the **official**
  `ghcr.io/github/github-mcp-server` v1.4.0 locally over stdio via Docker instead — a faithful
  stand-in for the GitHub MCP an enterprise user would have, and fully hermetic.
- **Auth without leaking a token:** the Docker arg `-e GITHUB_PERSONAL_ACCESS_TOKEN` (passthrough,
  no `=value`) makes docker inherit the var from claude's environment. `run.sh` exports it from
  `gh auth token`. **No secret is ever written to a committed file** (verified by secret scan).
- **Tool discovery:** a manual MCP handshake (`initialize` + `tools/list`) against the server —
  with `GITHUB_TOOLSETS=issues` to scope it — revealed the create tool is **`issue_write`**
  (method `create`), namespaced for claude as `mcp__github__issue_write`. (Note: stdin must be
  held open briefly or the server shuts down on EOF before flushing — see Investigation Trail.)
- **Least-privilege grant** (Spike 001 requirement): granted only `mcp__github__issue_write` +
  `Read Grep Glob` (repo investigation) — NOT `bypassPermissions`, NOT shell.

## How to Run

```sh
sh run.sh        # files a REAL issue into pulsedemon/netshooter, prefixed [spike-test]
```

`SPIKE_REPO` overrides the repo dir. Requires `gh` authed and Docker running.

## What to Expect

- exit 0, ~30s.
- A real `[spike-test]` issue created in `pulsedemon/netshooter`.
- `mcp__github__issue_write` tool_use present in the stream-json transcript (the tool truly fired).
- `parse-issue.js` prints the issue number + URL and the spoken string.

## Observability

Full `--output-format stream-json --verbose` transcript captured to `run-output.jsonl`: every
`tool_use` (repo Reads + the `issue_write` call with its exact input) and the final result. This
is ground truth that the issue was filed *by the tool*, not hallucinated. `parse-issue.js`
re-derives the issue number from it.

## Investigation Trail

1. **Picked the GitHub MCP source.** The pre-installed remote MCP was broken, so I ran the official
   server locally via Docker — hermetic and matches the real MCP's tool surface.
2. **Server returned nothing on first handshake.** `printf | docker run -i` hit EOF immediately and
   the server closed the session before flushing. Fixed by holding stdin open (`{ printf ...; sleep 4; }`),
   which then returned the full tool list. Discovered the real tool name: `issue_write`.
3. **Ran the end-to-end flow** in the netshooter repo. Exit 0, issue #89 filed.
4. **Independently confirmed** the issue with `gh issue view 89` (did not trust the model's claim):
   real, OPEN, author `milesangelo`, correct title/URL.
5. **Investigated why the parser fell back to prose regex.** Inspected the raw `issue_write`
   tool_result and found the schema landmine below — fixed the parser to read the structured `url`.

## Results

**Verdict: VALIDATED** — headless claude, run in the repo, investigated and filed a real GitHub
issue via MCP, and the number/URL is reliably parseable.

Independent ground-truth confirmation:
```
{"number":89,"state":"OPEN","author":"milesangelo",
 "title":"[spike-test] README: review/improve the \"Running Tests\" documentation",
 "url":"https://github.com/pulsedemon/netshooter/issues/89"}
```

Raw `issue_write` tool input (proves the tool fired with real args):
```
{"method":"create","owner":"pulsedemon","repo":"netshooter",
 "title":"[spike-test] README: review/improve the \"Running Tests\" documentation","body":"..."}
```

**Key findings (beyond the verdict):**

1. **End-to-end works headlessly.** ~30s, exit 0, no interaction. The 001 permission mechanic holds
   with a real MCP and a real side effect.

2. **🔴 Parse landmine: `id` ≠ issue number.** The `issue_write` result is
   `{"id":"4747398171","url":".../issues/89"}`. There is **no `number` field**, and `id` is GitHub's
   internal node id — an app that speaks `id` would announce "created issue 4747398171". The
   human-facing number lives **only in the url path** (`/issues/89`). The app MUST parse the number
   from the `url`, never from `id`. (This is why the first parser fell back to prose; fixed.)

3. **🟡 The CLI investigates and may OVERRIDE the transcript.** The transcript claimed the README
   "does not explain how to run the test suite." The model read the repo, found the README *already
   has* a Testing section, and filed an **accurate** issue (review/improve the existing docs) rather
   than a false "it's missing" one. This is genuinely valuable — it prevents filing wrong issues —
   but it means **voice → filed issue is not literal**, and v1 files automatically with *no review
   screen*. The user can't see or approve the divergence before it's public. This is a real product
   tension to flag for v1 (accuracy vs. fidelity-to-what-was-said + no-review).

4. **Two reliable output channels.** Both the structured `stream-json` tool_result (best — machine
   readable) and the final prose text contained the issue URL. `parse-issue.js` prefers the
   structured source and falls back to prose regex. The app should do the same.

5. **`GITHUB_TOOLSETS=issues` shrinks the attack surface** and speeds tool listing — the app should
   scope the MCP to just the toolset it needs.

**Requirements that emerged → recorded in MANIFEST.md.**

## Cleanup

Issue #89 is a real, OPEN `[spike-test]` artifact in pulsedemon/netshooter. Close it when done:
```sh
gh issue close 89 --repo pulsedemon/netshooter -c "Done with make-an-issue spike 002."
```
