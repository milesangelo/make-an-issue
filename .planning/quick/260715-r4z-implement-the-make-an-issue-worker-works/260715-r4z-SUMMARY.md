---
quick_id: 260715-r4z
status: complete
date: 2026-07-15
commit: c2dbf29
---

# Workspace and builtin publisher slice summary

Implemented the safety-critical `preparing` through `pr_opened` worker pipeline.

- Added the worker-owned repository store, builtin git-worktree backend, and isolated Treehouse durable-lease adapter.
- Added guarded branch/git operations, structural diff inspection, bounded artifacts/logs, worker-defined validation profiles, normal fresh-ref push, draft PR creation/read-back, and CI observation.
- Added append-only ledger artifact/event recording and frozen-config startup reconciliation for push-then-crash recovery.
- Added an explicitly gated fixture-provider/remote seam so the real worker executable is testable offline while production provider adapters remain fail-closed for the next slice.
- Kept the no-mistakes publisher backend fail-closed and made builtin capability reporting explicit in doctor.

Verification:

- `swift build` passed.
- `swift test` passed: 212 tests, 1 pre-existing skip, 0 failures.
- Offline bare-origin integration reached every state from `queued` through `pr_opened`, invoked fake `gh pr create --draft`, recorded CI, and left `main` unchanged.
- Sabotage coverage rejects force/ref deletion syntax, default-branch mutation, reused/divergent refs, non-draft PRs, empty/oversized/binary diffs, escaping symlinks, and `.gitmodules` changes.
- Validation-failed work retained its dirty workspace, patch, logs, and ledger disposition without a remote branch or PR.
