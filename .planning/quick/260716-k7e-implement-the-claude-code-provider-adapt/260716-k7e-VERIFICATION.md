---
quick_id: 260716-k7e
status: passed
verified: 2026-07-16
implementation_commit: 27ffe8b
---

# Verification: Claude Code worker provider adapter

## Must-have results

| Requirement | Result | Evidence |
|---|---|---|
| Typed configured Claude invocation in prepared workspace | PASS | Adapter test captures configured `--model sonnet`, adapter safety flags, stdin prompt, and workspace CWD; offline worker smoke uses the executable written into `agents.toml`. |
| Title, body, labels, and agent instructions injected safely | PASS | Prompt fixture asserts snapshotted instructions and JSON-escaped issue context beneath an explicit untrusted-data boundary. |
| Explicit child environment allowlist | PASS | Fixture child sees isolated HOME/TMPDIR/PWD, fixed PATH/locale, and allowed Anthropic auth; GitHub tokens, gh config, SSH socket, real HOME, and unrelated token-shaped variables are absent. |
| Timeout/cancel process-group teardown | PASS | Fixture providers fork 120-second children; timeout and cancellation return their distinct typed outcomes and both descendant PIDs are gone before return. |
| Machine-readable bounded outcome | PASS | Outcome carries status, PID, exit code, duration, stdout/stderr, and per-stream truncation; ledger stores compact JSON metadata without output bytes. |
| Redaction before artifact persistence | PASS | GitHub and Anthropic token shapes remain available only in the in-memory outcome; provider.log contains `[REDACTED]`, neither original token, and stays within the configured cap. |
| Ledger lifecycle integration | PASS | Prepared RunService flow records `provider_outcome`; successful smoke transitions `running -> validating -> publishing -> pr_opened`. |
| Publication invariants unchanged | PASS | Offline smoke creates/read-backs a draft PR, leaves default branch unchanged, and validation failure creates no remote branch or PR. |

## Commands

- `swift test --filter ProviderAdapterTests` — 5 passed.
- `swift test --filter WorkerArtifactSmokeTests` — 2 passed.
- `swift test --filter 'ProviderAdapterTests|WorkerArtifactSmokeTests|ProcessExecutorTests'` — 12 passed.
- `swift test` — 207 tests, 1 expected skip, 0 failures.
- `git diff --check` — passed.

No live provider/model or GitHub network call was used.
