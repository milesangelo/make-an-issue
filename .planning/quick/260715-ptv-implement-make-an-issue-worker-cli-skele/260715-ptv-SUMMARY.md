---
quick_id: 260715-ptv
status: complete
completed: 2026-07-15
implementation_commit: 45c50d7
---

# Quick Task 260715-ptv Summary

Implemented the first vertical slice of `make-an-issue-worker` as a separate SwiftPM executable
and testable core library.

## Delivered

- Strict schema-v1 TOML loading with secure descriptor-based reads, exact-byte SHA-256 revisions,
  unknown-key rejection, typed providers, referenced instruction snapshots, route tie detection,
  and repository/remote validation.
- SQLite WAL ledger with durable run groups, full state-machine transitions, immutable terminal
  records, append-only events, one non-terminal run per issue, transactional host claim, cleanup
  projection fields, and startup/publication reconciliation queries.
- Human-readable `doctor` checks for config, provider executables/auth, Treehouse, no-mistakes
  capability proof and builtin fallback, `gh` auth, and state-root health.
- `run --issue [--agent]` URL/trust/default-branch/routing flow that records and claims the run,
  reaches `preparing`, and deliberately records `publisher_slice_not_implemented` without touching
  a workspace, provider, git repository, or publication API.
- Unit and artifact smoke coverage for config failures, routes, ledger guarantees, doctor seams,
  concurrent claims, explicit reruns, CLI parsing, and the documented exit-code-3 stub.

## Verification

- Clean `swift build` produced both `MakeAnIssue` and `make-an-issue-worker`.
- Full `swift test`: 202 tests executed, 1 pre-existing smoke test skipped, 0 failures.
- Worker-core and CLI targets build with warnings treated as errors.
- Real-machine `doctor`: Claude authenticated, Treehouse v2.0.0 present, `gh` authenticated,
  state root writable, and installed no-mistakes v1.34.0 correctly rejected for missing capability
  proof with builtin selected under `auto`.
- `git diff --check` passed.

## Deferred by contract

Workspace acquisition, provider execution, validation/publication adapters, polling, LaunchAgent,
and menu-app integration remain follow-up slices.
