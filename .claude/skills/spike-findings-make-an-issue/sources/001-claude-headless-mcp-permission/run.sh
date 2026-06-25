#!/bin/sh
# Spike 001 — prove `claude -p` (headless, no TTY) invokes an MCP tool with NO
# interactive approval. Runs three cases and records evidence to ./tool-calls.log.
#
#   A. allowedTools scoped to the exact MCP tool   -> expect: ping runs, no hang
#   B. permission-mode bypassPermissions           -> expect: ping runs, no hang
#   C. NO permission grant (default)               -> expect: tool BLOCKED (the boundary)
#
# A hang (timeout) in A/B would mean headless mode still waits for human approval
# = the idea-killer. C maps the boundary so the real app knows what it MUST pass.
set -u
cd "$(dirname "$0")"

TOOL="mcp__stub__ping"
CFG="mcp-config.json"
PROMPT="Call the ping tool exactly once with note set to the string TESTNOTE, then tell me what it returned. Do not ask for confirmation."
TIMEOUT=90

# Portable hard timeout: run claude in background, watchdog kills it if it hangs.
run_with_timeout() {
  label="$1"; shift
  : > /tmp/spike001-out.txt
  "$@" > /tmp/spike001-out.txt 2>&1 &
  pid=$!
  ( sleep "$TIMEOUT"; kill -9 "$pid" 2>/dev/null && echo "__WATCHDOG_KILLED__" >> /tmp/spike001-out.txt ) &
  watchdog=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$watchdog" 2>/dev/null
  echo "exit_rc=$rc"
  cat /tmp/spike001-out.txt
}

echo "############################################################"
echo "# CASE A: --allowedTools $TOOL (scoped grant)"
echo "############################################################"
COUNT_BEFORE=$(grep -c '"tool":"ping"' tool-calls.log 2>/dev/null || echo 0)
START=$(date +%s)
run_with_timeout "A" claude -p "$PROMPT" \
  --mcp-config "$CFG" --strict-mcp-config \
  --allowedTools "$TOOL" \
  --output-format json
END=$(date +%s)
COUNT_AFTER=$(grep -c '"tool":"ping"' tool-calls.log 2>/dev/null || echo 0)
echo "--- CASE A: elapsed=$((END-START))s  ping_calls_logged: before=$COUNT_BEFORE after=$COUNT_AFTER"

echo ""
echo "############################################################"
echo "# CASE B: --permission-mode bypassPermissions"
echo "############################################################"
COUNT_BEFORE=$COUNT_AFTER
START=$(date +%s)
run_with_timeout "B" claude -p "$PROMPT" \
  --mcp-config "$CFG" --strict-mcp-config \
  --permission-mode bypassPermissions \
  --output-format json
END=$(date +%s)
COUNT_AFTER=$(grep -c '"tool":"ping"' tool-calls.log 2>/dev/null || echo 0)
echo "--- CASE B: elapsed=$((END-START))s  ping_calls_logged: before=$COUNT_BEFORE after=$COUNT_AFTER"

echo ""
echo "############################################################"
echo "# CASE C: NO permission grant (default mode) -- expect BLOCKED"
echo "############################################################"
COUNT_BEFORE=$COUNT_AFTER
START=$(date +%s)
run_with_timeout "C" claude -p "$PROMPT" \
  --mcp-config "$CFG" --strict-mcp-config \
  --output-format json
END=$(date +%s)
COUNT_AFTER=$(grep -c '"tool":"ping"' tool-calls.log 2>/dev/null || echo 0)
echo "--- CASE C: elapsed=$((END-START))s  ping_calls_logged: before=$COUNT_BEFORE after=$COUNT_AFTER"

echo ""
echo "############################################################"
echo "# FORENSIC LOG (tool-calls.log) — ground truth of actual invocations"
echo "############################################################"
cat tool-calls.log 2>/dev/null || echo "(no log — tool never executed)"
