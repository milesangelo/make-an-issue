---
spike: 001
name: claude-headless-mcp-permission
type: standard
validates: "Given `claude -p` (headless, no TTY) with an MCP server configured, when told to call an MCP tool, then the tool executes with no interactive approval and output is captured"
verdict: VALIDATED
related: [002]
tags: [claude, mcp, headless, permissions]
---

# Spike 001: claude-headless-mcp-permission

## What This Validates

Given `claude -p` (print/headless mode, no TTY), when it is told to call a tool exposed by an
MCP server, then the tool **actually executes without any human approving a permission prompt**,
and the result is captured on stdout.

This is the **idea-killer gate** for make-an-issue: the whole v1 architecture assumes the app can
shell out to the user's AI CLI non-interactively and have it *file an issue* via MCP. If a headless
CLI cannot use an MCP tool without a human clicking "approve," the entire concept is dead.

Isolated deliberately: a **local stub MCP server** with one read-only `ping` tool (zero external
side effects) so we test the *permission mechanic* alone, not GitHub/Jira/network noise.

## Research

`claude --help` confirmed the headless surface area:
- `-p / --print` — non-interactive, print-and-exit.
- `--mcp-config <json>` — load MCP servers from a JSON file (`{ "mcpServers": { ... } }`).
- `--strict-mcp-config` — use ONLY the servers from `--mcp-config` (ignore the user's global MCP
  config) — keeps the spike hermetic.
- `--allowedTools "mcp__<server>__<tool>"` — pre-grant specific tools. MCP tools are namespaced
  `mcp__<serverName>__<toolName>`.
- `--permission-mode <mode>` — `default | acceptEdits | bypassPermissions | plan`.
- `--output-format json` — structured result envelope (includes a `permission_denials` array).

No external library needed — the stub server implements the minimal MCP JSON-RPC handshake
(`initialize`, `tools/list`, `tools/call`) in dependency-free Node over stdio.

## How to Run

```sh
sh run.sh
```

Runs three cases back-to-back, each with a 90s watchdog that would catch a hang (a hang = the
CLI waiting for human approval = the kill scenario):

- **A** — `--allowedTools mcp__stub__ping` (scoped least-privilege grant)
- **B** — `--permission-mode bypassPermissions` (grant everything)
- **C** — no grant, default mode (maps the boundary — expected to be blocked)

## What to Expect

- A & B: exit 0, no watchdog kill, result text `pong (note=TESTNOTE)`, a new line appended to
  `tool-calls.log`.
- C: exit 0 (does **not** hang), result text says the call was blocked, `permission_denials`
  populated, and **no** new line in `tool-calls.log` (tool never ran).

## Observability

`stub-mcp-server.js` appends one JSON line to `tool-calls.log` on every real `ping` invocation —
this is ground-truth evidence the tool executed (independent of what claude *says* on stdout).
Cross-checking the log line count against claude's output catches both false positives (claude
claims success but tool didn't run) and false negatives.

## Investigation Trail

1. **Built the isolated probe.** Chose a local stub MCP over a real read-only server (context7)
   so the only variable is the permission mechanic — no network, no auth, no rate limits.
2. **Designed for the failure mode, not just success.** The real fear was a *hang* (headless CLI
   blocking on an un-answerable TTY prompt). Added a watchdog timeout so a hang would be visible
   as a kill, and added Case C to find the exact boundary.
3. **Ran all three cases.** Results below. Case C surfaced a finding I didn't expect (see Results).

## Results

**Verdict: VALIDATED** — headless `claude -p` invokes MCP tools non-interactively when granted.

Forensic log (`tool-calls.log`) — ground truth, ping ran exactly twice (cases A + B), never in C:
```
{"ts":"2026-06-25T21:00:43.437Z","category":"tool-call","detail":{"tool":"ping","args":{"note":"TESTNOTE"}}}
{"ts":"2026-06-25T21:00:51.527Z","category":"tool-call","detail":{"tool":"ping","args":{"note":"TESTNOTE"}}}
```

| Case | Grant | Elapsed | Hang? | Tool ran? | `permission_denials` | Result |
|------|-------|---------|-------|-----------|----------------------|--------|
| A | `--allowedTools mcp__stub__ping` | 12s | no | ✅ yes | `[]` | `pong (note=TESTNOTE)` |
| B | `--permission-mode bypassPermissions` | 8s | no | ✅ yes | `[]` | `pong (note=TESTNOTE)` |
| C | none (default) | 12s | **no** | ❌ no | `[{tool_name:"mcp__stub__ping",...}]` | blocked, clean return |

**Key findings (beyond the verdict):**

1. **The kill-risk is dead.** A scoped `--allowedTools` grant is sufficient for non-interactive
   MCP tool use. No human in the loop, no TTY, no hang.
2. **Default mode does NOT freeze — it auto-denies and returns (exit 0).** This was the surprise.
   The fear was that an un-granted tool call would block forever waiting for approval. Instead
   claude returns cleanly with the tool listed in `permission_denials`. So a *misconfigured* app
   fails fast and detectably rather than hanging the menu-bar UI.
3. **`permission_denials` is a machine-readable failure signal.** With `--output-format json`, the
   app can detect "the CLI couldn't file because the tool wasn't granted" by checking this array —
   distinct from a network/MCP error. Useful for clear error messaging.
4. **Least-privilege grant beats bypass.** Both A and B work, but `--allowedTools` scoped to the
   single issue-creation tool is the safe choice — `bypassPermissions` grants the CLI *every*
   tool (file writes, shell, etc.) which is needless risk for an app that only needs "file issue."
5. **Cost is real.** ~$0.33–0.35 per invocation here (opus-4-8[1m], inherited from my config, 3
   turns each). The real app should pin a model and may want a cheaper/faster one — every voice
   capture triggers a paid CLI run. Not a blocker; a budgeting note for the build.

**Requirements that emerged → recorded in MANIFEST.md.**
