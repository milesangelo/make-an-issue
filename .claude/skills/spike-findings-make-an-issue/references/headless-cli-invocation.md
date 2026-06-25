# Headless CLI Invocation (the permission mechanic)

How the app shells out to the user's `claude` CLI **non-interactively** and gets it to call
an MCP tool with no human approving a permission prompt. This is the idea-killer gate — proven
dead-as-a-risk in spike 001.

## Requirements

- The app MUST pass an explicit, **scoped** tool grant: `--allowedTools "mcp__<server>__<tool>"`
  (least privilege), NOT `--permission-mode bypassPermissions` (which grants every tool incl.
  shell/file-write).
- The app MUST invoke the CLI with structured output (`--output-format json` or `stream-json`)
  and inspect the `permission_denials` array to distinguish "tool not granted" from MCP/network
  errors.
- A populated `permission_denials` MUST be treated as a failure (no issue was filed) — even
  though the CLI returns exit 0.

## How to Build It

The core invocation (matches what the app should emit):

```sh
claude -p "<prompt>" \
  --mcp-config <abs-path-to.json> --strict-mcp-config \
  --allowedTools "mcp__<server>__<tool>" "Read" "Grep" "Glob" \
  --output-format stream-json --verbose
```

Flags that matter:
- `-p / --print` — non-interactive, print-and-exit. No TTY.
- `--mcp-config <json>` — load MCP servers from `{ "mcpServers": { ... } }`. Use an **absolute
  path** so it resolves even when cwd is set to another repo.
- `--strict-mcp-config` — use ONLY the servers from `--mcp-config`, ignore the user's global MCP
  config. Keeps invocation hermetic and predictable.
- `--allowedTools "mcp__<server>__<tool>" ...` — pre-grant exactly the tools needed. MCP tools
  are namespaced `mcp__<serverName>__<toolName>`. Add only the built-ins the task needs
  (`Read Grep Glob` for repo investigation).
- `--output-format json` (single envelope) or `stream-json --verbose` (event stream incl.
  `tool_use`/`tool_result` blocks — preferred when you need to verify the tool actually ran).

Minimal MCP config (`mcp-config.json`):

```json
{ "mcpServers": { "stub": { "command": "node", "args": ["stub-mcp-server.js"] } } }
```

Wrap the call in a **watchdog timeout**. Background the process; kill it after N seconds. A hang
would mean the CLI is waiting on an un-answerable interactive prompt (the original fear):

```sh
"$@" > out.txt 2>&1 &
pid=$!
( sleep 90; kill -9 "$pid" 2>/dev/null && echo "__WATCHDOG_KILLED__" >> out.txt ) &
watchdog=$!
wait "$pid"; rc=$?
kill "$watchdog" 2>/dev/null
```

## What to Avoid

- **Do NOT use `--permission-mode bypassPermissions` in the app path.** It works (proven in
  spike 001 case B) but grants *every* tool including shell and file-write — needless attack
  surface when a scoped `--allowedTools` grant does the job.
- **Do NOT assume an un-granted tool hangs.** It does not. Default mode auto-denies and returns
  exit 0 with the tool listed in `permission_denials` — so the app fails fast and detectably,
  but it MUST inspect `permission_denials` rather than trusting exit code 0 alone.
- **Do NOT trust the model's prose** ("I called the tool") as proof a side effect happened.
  Verify forensically (see Constraints).

## Constraints

- Spike 001 case timings: scoped grant ~12s, bypass ~8s, denied-boundary ~12s. Budget the
  app's timeout well above this (90s watchdog used in the spike).
- `permission_denials` entry shape: `[{ tool_name: "mcp__stub__ping", ... }]`.
- A dependency-free Node MCP server over stdio needs only `initialize` →
  `notifications/initialized` → `tools/list` / `tools/call`, line-delimited JSON-RPC 2.0.
  `notifications/*` (no `id`) get no response. (~120 lines — see the stub source.)

## Origin

Synthesized from spikes: 001 (permission mechanic in isolation), 002 (same flags against a real MCP).
Source files available in: sources/001-claude-headless-mcp-permission/, sources/002-claude-github-file-issue/
