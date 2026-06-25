# GitHub Issue Filing & Output Parsing

How the app, running `claude -p` inside the bound repo, gets a real GitHub issue filed via the
GitHub MCP and then parses the new issue `#number` + URL to speak it back. Proven end-to-end in
spike 002 (filed real issue #89 in pulsedemon/netshooter, ~30s, no interaction).

## Requirements

- The app MUST run the AI CLI with **cwd = the bound repo** so it investigates the real code
  before drafting (this is where the value comes from — see "What to Avoid" #3).
- 🔴 The app MUST parse the new issue number from the **`url`** in the `issue_write` result
  (`.../issues/<N>`), **NEVER from the `id` field** — `id` is GitHub's internal node id, not the
  issue number. Prefer the structured `stream-json` tool_result; fall back to prose-text regex.
- The app should scope the MCP to the minimal toolset (`GITHUB_TOOLSETS=issues`) and pass the
  token via env passthrough, never writing it to a config file.
- 🟡 v1 files automatically with no review screen, BUT the CLI may file an issue that diverges
  from the literal transcript (it corrects false premises). This accuracy-vs-fidelity tension
  must be an explicit, accepted v1 decision — or v1 needs a lightweight confirm step. **Flagged
  for discuss/plan.**

## How to Build It

MCP config — GitHub's official server over stdio via Docker, scoped to issues, token by passthrough:

```json
{
  "mcpServers": {
    "github": {
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "-e", "GITHUB_PERSONAL_ACCESS_TOKEN",
        "-e", "GITHUB_TOOLSETS=issues",
        "ghcr.io/github/github-mcp-server"
      ]
    }
  }
}
```

Note `-e GITHUB_PERSONAL_ACCESS_TOKEN` with **no `=value`** — Docker inherits it from the
environment. Source it from `gh auth token` and export before invoking:

```sh
export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)"
[ -n "$GITHUB_PERSONAL_ACCESS_TOKEN" ] || { echo "ERROR: no gh token"; exit 1; }
```

Invoke headless **inside the repo**, granting only `issue_write` + repo-read built-ins:

```sh
( cd "$REPO" && claude -p "$PROMPT" \
    --mcp-config "$SPIKE_DIR/mcp-config.json" --strict-mcp-config \
    --allowedTools "mcp__github__issue_write" "Read" "Grep" "Glob" \
    --output-format stream-json --verbose )
```

The create-issue tool is **`issue_write`** with **`method=create`**. Tell the model explicitly:
"file the issue using the issue_write tool with method=create" and "Do not ask for confirmation."

Parse the result, structured source first, prose regex as fallback. The `issue_write` result is
`{"id":"<node-id>","url":".../issues/<N>"}` — there is **no `number` field**:

```js
// Walk stream-json tool_result blocks for the issue URL; number lives ONLY in the path.
const m = text.match(/"url"\s*:\s*"(https?:\/\/github\.com\/[^"]+\/issues\/(\d+))"/) ||
          text.match(/"html_url"\s*:\s*"([^"]+\/issues\/(\d+))"/);
if (m) result = { number: +m[2], url: m[1] };
// Fallback: regex the final assistant text for /issues/<N> or #<N>.
```

Verify the tool actually fired (forensic, don't trust prose) by grepping the stream for the
`tool_use` event: `grep -o '"name":"mcp__github__issue_write"' output.jsonl`.

## What to Avoid

- 🔴 **Never speak `id`.** `id` (e.g. `4747398171`) is the internal node id. An app that speaks
  `id` announces "created issue 4747398171" instead of "#89". The human-facing number is **only**
  in the url path. This was the first parser's bug — fixed by parsing the url.
- **Don't expect a `number` field** in the result JSON — it isn't there.
- **Don't treat voice → filed issue as literal.** The CLI investigates and may *override* the
  transcript. In spike 002 the transcript claimed the README "does not explain how to run tests";
  the model read the repo, found an existing Testing section, and filed an accurate "review/improve
  the docs" issue instead. Valuable (prevents wrong issues) but means the filed issue ≠ what was
  said, and v1 files with no review screen.

## Constraints

- GitHub MCP image: `ghcr.io/github/github-mcp-server` (v1.4.0 at spike time), run locally over
  stdio via Docker. Docker must be available on the user's machine.
- End-to-end latency ~30s (includes repo investigation + filing).
- MCP stdio gotcha when probing the server manually: hold stdin open briefly
  (`{ printf '...'; sleep 4; } | docker run -i ...`) or it shuts down on EOF before flushing.
- Two reliable output channels: the structured `stream-json` tool_result (best) and the final
  prose text both carried the URL. Prefer structured, fall back to prose.

## Origin

Synthesized from spikes: 002 (full claude+GitHub happy path, real issue filed & parsed).
Source files available in: sources/002-claude-github-file-issue/
