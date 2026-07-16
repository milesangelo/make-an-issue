---
quick_id: 260716-k7e
status: complete
date: 2026-07-16
commit: 27ffe8b
---

# Claude Code worker provider adapter summary

Implemented the configured Claude Code provider path from prepared workspace through the worker ledger's validating transition.

- Added a typed provider seam and Claude Code adapter using configured absolute executable plus literal argv, adapter-owned edit-only/structured-output flags, prompt-file stdin transport, executable identity recheck, and prepared-workspace CWD.
- Added issue body collection and a bounded prompt combining snapshotted trusted agent instructions with JSON-quoted untrusted issue title, body, and labels.
- Extended the shared `ProcessExecutor` with prompt-file stdin, cancellation, duration/PID metadata, dual-stream truncation flags, and existing process-group TERM-to-KILL teardown; no second executor was introduced.
- Added a fixed provider environment allowlist with isolated HOME/temp/PWD, minimal system PATH/locale, Claude/Anthropic credential variables only, and no GitHub, gh-config, SSH-agent, or arbitrary worker environment inheritance.
- Added typed completed/failed/timed-out/cancelled outcomes, compact JSON ledger events, distinct retained failure codes, and redaction/capping before provider logs are persisted.
- Replaced the RunService fixture-provider environment hook with the configured provider adapter while retaining only the existing offline remote fixture gate.

Verification:

- `ProviderAdapterTests`: success/configured argv/prompt/env, nonzero exit, token redaction, timeout child-tree kill, cancellation child-tree kill, and ledger metadata all pass.
- `WorkerArtifactSmokeTests`: the built worker executes a provider from `agents.toml` through a real prepared workspace and reaches a verified draft PR; validation failure retains work and publishes nothing.
- Installed Claude Code `2.1.211` help confirms `--print`, `--permission-mode acceptEdits`, `--allowedTools`, `--output-format stream-json`, and `--verbose` are supported.
- Full `swift test` passed with 207 tests, 1 expected skip, and 0 failures.
- `git diff --check` passed.
