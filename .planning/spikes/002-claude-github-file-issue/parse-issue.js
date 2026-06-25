#!/usr/bin/env node
// Demonstrates the app's parsing step: extract the new issue number + URL from the
// AI CLI's output so it can be spoken ("created issue #NUMBER").
//
// Tries two sources, most-reliable first:
//   1. The MCP tool_result in the stream-json transcript (structured: number, html_url).
//   2. Regex over the final assistant text (what a plain --output-format text app would see).
//
// Usage: node parse-issue.js run-output.jsonl

const fs = require('fs');
const file = process.argv[2] || 'run-output.jsonl';
const lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim());

let fromToolResult = null;
let finalText = '';

for (const line of lines) {
  let msg;
  try { msg = JSON.parse(line); } catch { continue; }

  // Capture the final assistant/result text.
  if (msg.type === 'result' && typeof msg.result === 'string') finalText = msg.result;

  // Walk message content for tool_result blocks containing the created issue.
  const content = msg.message && msg.message.content;
  if (Array.isArray(content)) {
    for (const block of content) {
      if (block.type === 'tool_result') {
        const text = Array.isArray(block.content)
          ? block.content.map((c) => c.text || '').join('')
          : (block.content || '');
        // The GitHub MCP `issue_write` result is `{"id":"<node-id>","url":".../issues/<N>"}`.
        // CRITICAL: `id` is GitHub's internal node id, NOT the issue number. The human-facing
        // number lives ONLY in the url path (/issues/<N>). Never speak `id`.
        const m = text.match(/"url"\s*:\s*"(https?:\/\/github\.com\/[^"]+\/issues\/(\d+))"/) ||
                  text.match(/"html_url"\s*:\s*"([^"]+\/issues\/(\d+))"/);
        if (m) fromToolResult = { number: +m[2], url: m[1] };
      }
    }
  }
}

// Fallback: regex the final text.
function fromText(t) {
  const url = (t.match(/https?:\/\/github\.com\/[^\s)"']+\/issues\/(\d+)/) || [])[0];
  const num = url ? +url.match(/\/issues\/(\d+)/)[1] : (t.match(/#(\d+)/) || [])[1];
  return url || num ? { number: num ? +num : null, url: url || null } : null;
}

const result = fromToolResult || fromText(finalText);

console.log('--- parse-issue ---');
console.log('source:', fromToolResult ? 'mcp tool_result (structured)' : 'final-text regex (fallback)');
if (result && result.number) {
  console.log('issue_number:', result.number);
  console.log('issue_url:', result.url);
  console.log('SPEAK:', `created issue number ${result.number}`);
  process.exit(0);
} else {
  console.log('PARSE FAILED — no issue number/URL found in output');
  process.exit(1);
}
