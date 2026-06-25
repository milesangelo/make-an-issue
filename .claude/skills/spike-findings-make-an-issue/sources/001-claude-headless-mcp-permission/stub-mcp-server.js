#!/usr/bin/env node
// Minimal, dependency-free MCP server over stdio (JSON-RPC 2.0, line-delimited).
// Exposes ONE read-only tool, `ping`, that appends a forensic line to a log file
// every time it is invoked and returns "pong". Zero external side effects.
//
// Purpose: prove that `claude -p` (headless, no TTY) actually invokes an MCP tool
// non-interactively. The log file is the ground-truth evidence the tool ran.

const fs = require('fs');
const path = require('path');

const LOG_FILE = path.join(__dirname, 'tool-calls.log');

function log(category, detail) {
  const line = JSON.stringify({ ts: new Date().toISOString(), category, detail }) + '\n';
  fs.appendFileSync(LOG_FILE, line);
}

// stderr is safe for diagnostics; stdout is reserved for JSON-RPC frames.
function diag(msg) {
  process.stderr.write(`[stub-mcp] ${msg}\n`);
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

let buffer = '';
process.stdin.on('data', (chunk) => {
  buffer += chunk.toString('utf8');
  let idx;
  while ((idx = buffer.indexOf('\n')) >= 0) {
    const raw = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (raw) handleLine(raw);
  }
});

function handleLine(raw) {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch (e) {
    diag(`unparseable line: ${raw}`);
    return;
  }

  const { id, method, params } = msg;

  // Notifications (no id) get no response.
  if (method === 'notifications/initialized') {
    diag('client initialized');
    return;
  }

  if (method === 'initialize') {
    // Echo the client's protocol version for compatibility.
    const protocolVersion = (params && params.protocolVersion) || '2025-06-18';
    diag(`initialize (protocol ${protocolVersion})`);
    send({
      jsonrpc: '2.0',
      id,
      result: {
        protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: 'stub-mcp', version: '0.0.1' },
      },
    });
    return;
  }

  if (method === 'tools/list') {
    send({
      jsonrpc: '2.0',
      id,
      result: {
        tools: [
          {
            name: 'ping',
            description:
              'Read-only probe. Records that it was called and returns "pong". Use this when asked to ping.',
            inputSchema: {
              type: 'object',
              properties: {
                note: { type: 'string', description: 'Optional note to record with the call.' },
              },
            },
          },
        ],
      },
    });
    return;
  }

  if (method === 'tools/call') {
    const toolName = params && params.name;
    const args = (params && params.arguments) || {};
    if (toolName === 'ping') {
      log('tool-call', { tool: 'ping', args });
      diag(`ping invoked with args ${JSON.stringify(args)}`);
      send({
        jsonrpc: '2.0',
        id,
        result: {
          content: [{ type: 'text', text: `pong (note=${args.note || 'none'})` }],
        },
      });
      return;
    }
    send({
      jsonrpc: '2.0',
      id,
      error: { code: -32601, message: `unknown tool: ${toolName}` },
    });
    return;
  }

  // Unknown method that expects a response.
  if (id !== undefined) {
    send({ jsonrpc: '2.0', id, error: { code: -32601, message: `unknown method: ${method}` } });
  }
}

diag('stub MCP server started, waiting on stdio');
