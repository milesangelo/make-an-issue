#!/bin/sh
# Spike 002 — prove the full claude+GitHub happy path, headless and non-interactive:
# run `claude -p` INSIDE the bound repo (like the app does), have it investigate the
# repo, draft an issue from a voice transcript, and FILE it via the GitHub MCP, then
# parse the new issue #number + URL from the output (the app speaks it back).
#
# Faithful to the app:
#   - cwd = the bound repo (~/source/netshooter), so the CLI investigates real code
#   - least-privilege grant (Spike 001 requirement): only repo-read tools + issue_write
#   - token never touches a file: passed via `-e GITHUB_PERSONAL_ACCESS_TOKEN` passthrough
set -u
SPIKE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${SPIKE_REPO:-$HOME/source/netshooter}"
OWNER_REPO="pulsedemon/netshooter"
OUT="$SPIKE_DIR/run-output.jsonl"

# Real GitHub token, minted from gh auth — exported so the docker MCP inherits it.
export GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)"
[ -n "$GITHUB_PERSONAL_ACCESS_TOKEN" ] || { echo "ERROR: no gh token"; exit 1; }

TRANSCRIPT="The README does not explain how to run the test suite. We should add a short Running Tests section so new contributors know the command to use."

PROMPT="You are make-an-issue: you turn a developer's spoken thought into a GitHub issue for the repository in the current working directory ($OWNER_REPO).

Spoken transcript: \"$TRANSCRIPT\"

Steps:
1. Briefly investigate the repo (README, test config) to write a specific, accurate issue.
2. File the issue in $OWNER_REPO using the issue_write tool with method=create.
3. Prefix the title with '[spike-test] '. Append a final body line: 'Filed automatically by make-an-issue spike 002 — safe to close.'
4. After filing, state the new issue number and URL.

Do not ask for confirmation; file it directly."

echo "=== running headless claude in $REPO ==="
START=$(date +%s)
( cd "$REPO" && claude -p "$PROMPT" \
    --mcp-config "$SPIKE_DIR/mcp-config.json" --strict-mcp-config \
    --allowedTools "mcp__github__issue_write" "Read" "Grep" "Glob" \
    --output-format stream-json --verbose ) > "$OUT" 2>"$SPIKE_DIR/run-stderr.txt"
RC=$?
END=$(date +%s)
echo "exit_rc=$RC  elapsed=$((END-START))s  output_lines=$(wc -l < "$OUT")"

echo ""
echo "=== forensic: was issue_write actually invoked? (tool_use events) ==="
grep -o '"name":"mcp__github__issue_write"' "$OUT" | head -1 \
  && echo "  -> issue_write tool_use present" \
  || echo "  -> issue_write NOT called"

echo ""
echo "=== final assistant result text ==="
node -e 'const fs=require("fs");for(const l of fs.readFileSync(process.argv[1],"utf8").split("\n")){if(!l.trim())continue;try{const m=JSON.parse(l);if(m.type==="result"&&typeof m.result==="string")console.log(m.result)}catch(e){}}' "$OUT"

echo ""
echo "=== parse step (what the app would speak) ==="
node "$SPIKE_DIR/parse-issue.js" "$OUT"
