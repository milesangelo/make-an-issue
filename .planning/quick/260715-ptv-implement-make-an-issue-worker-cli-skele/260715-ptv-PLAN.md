---
quick_id: 260715-ptv
status: complete
mode: quick-inline
date: 2026-07-15
---

# Quick Task 260715-ptv: Implement the first make-an-issue-worker vertical slice

## Goal

Add a buildable `make-an-issue-worker` executable foundation that strictly loads schema-v1
configuration, records and claims runs in SQLite, diagnoses local prerequisites behind testable
seams, and deliberately stops CLI runs at the publisher boundary without touching a workspace,
provider, git repository, or remote publication state.

## Must haves

- `swift build` emits both existing app and worker products; the existing app behavior stays intact.
- Config validation implements the product contract's schema, filesystem checks, revision snapshot,
  references, route-priority fail-closed rules, and precise keyed errors.
- The ledger enforces legal transitions, terminal immutability, append-only events/history,
  one non-terminal run per repository/issue, and the transactional host singleton claim.
- `doctor` reports blocking/non-blocking capability truth and selects builtin publication under
  `auto` when no-mistakes cannot prove draft-safe publication.
- `run --issue` verifies the configured repository and local caller trust, resolves labels or an
  explicit agent, records/claims/transitions the run, and exits at the tested publisher stub.
- Tests use fakes and local fixtures only; no provider, git mutation, or network operation occurs.

## Tasks

### 1. Add worker targets, strict configuration, URL parsing, and route resolution

Files: `Package.swift`, `Sources/MakeAnIssueWorkerCore/**`, `Sources/MakeAnIssueWorkerCLI/**`

Implement typed schema-v1 models and secure file loading, strict TOML key validation, immutable
config snapshots, issue URL parsing, repository lookup, and deterministic route/agent selection.

Verify: focused config and routing tests cover valid fixtures, unknown keys/kinds, schema mismatch,
bad references, duplicate route priorities, and URL/repository rejection.

### 2. Add SQLite ledger, doctor probes, and the deliberate run stub

Files: `Sources/CSQLite/**`, `Sources/MakeAnIssueWorkerCore/**`, `Sources/MakeAnIssueWorkerCLI/**`

Implement durable ledger schema/queries, transition events, immutability triggers, host claim,
reconciliation query hooks, subprocess probe seams, honest doctor verdicts, and CLI orchestration.

Verify: focused tests exercise transition legality, terminal immutability, rerun history,
non-terminal uniqueness, host claim conflict/release, startup query hooks, provider/workspace/
publisher/gh/state-root doctor verdicts, and the publisher-stub failure boundary.

### 3. Finish fixtures, documentation pointer, and full verification

Files: `Tests/MakeAnIssueWorkerTests/**`, `README.md`, `.planning/STATE.md`, quick-task summary

Add isolated executable/config fixtures, keep the README pointer to one short paragraph, run the
complete suite/build and local doctor/run smoke checks, inspect the diff, and commit atomically.

Verify: `swift test`, `swift build`, executable presence, fake-path run smoke, real-machine doctor,
`git diff --check`, and clean committed branch state.
