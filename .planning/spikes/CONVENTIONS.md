# Spike Conventions

Patterns and stack choices established across spike sessions. New spikes follow these unless the
question requires otherwise.

## Stack

- **Harness = POSIX `sh` `run.sh` + dependency-free Node.** The product is a Swift/macOS app, but
  spikes probe CLI/MCP behavior, so the fastest runnable harness is a shell driver plus small Node
  helpers. No `npm install`, no build step — Node's stdlib only.
- **MCP servers over stdio** speak newline-delimited JSON-RPC 2.0 (`initialize` →
  `notifications/initialized` → `tools/list` / `tools/call`). A ~120-line dependency-free Node
  server is enough to stand one up (see 001's `stub-mcp-server.js`).

## Structure

- One dir per spike: `NNN-descriptive-name/` containing `run.sh`, `README.md` (with frontmatter),
  the MCP config (`mcp-config.json`), and any Node helpers (`*.js`).
- `run.sh` resolves its own dir (`SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"`) and uses absolute
  paths for `--mcp-config`, so it runs correctly even with `cwd` set to another repo.

## Patterns

- **Headless claude invocation (the core mechanic):**
  `claude -p "<prompt>" --mcp-config <abs.json> --strict-mcp-config --allowedTools "mcp__<srv>__<tool>" --output-format stream-json --verbose`
- **Least privilege always.** Grant the exact MCP tool (`mcp__server__tool`) + only the built-ins
  the task needs (`Read Grep Glob`). Never `--permission-mode bypassPermissions` in the app path.
- **Forensic verification, never trust the model's claim.** Capture a ground-truth record of side
  effects independent of the model's prose: a stub server's append-only log (001), the
  `stream-json` `tool_use`/`tool_result` transcript (002), and an out-of-band check (`gh issue
  view`) confirming the real artifact exists.
- **Watchdog timeout** around any headless CLI call to detect a hang (a hang = waiting for an
  un-answerable interactive prompt). Background the process; kill it after N seconds.
- **Run the CLI with `cwd` = the real bound repo** when the spike depends on repo investigation.

## Tools & Libraries

- `ghcr.io/github/github-mcp-server` (v1.4.0) — official GitHub MCP, run locally over stdio via
  Docker. Create-issue tool: **`issue_write`** (method `create`); result is `{id, url}` where
  `id` is an internal node id and the issue number is only in `url` (`/issues/<N>`). Scope with
  `GITHUB_TOOLSETS=issues`.
- **Secret hygiene:** pass tokens via Docker `-e VAR` passthrough (no `=value`) sourced from
  `gh auth token` and exported in `run.sh`; never write a token into a committed file. Secret-scan
  (`grep -rE 'gho_|ghp_|github_pat_'`) the spike dir before committing.
- MCP stdio gotcha: when probing a server manually, hold stdin open briefly
  (`{ printf '...'; sleep 4; } | docker run -i ...`) or it shuts down on EOF before flushing.
