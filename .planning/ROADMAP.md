# Roadmap: make-an-issue

## Milestones

- ✅ **v1.0 MVP** — Phases 1–4 (shipped 2026-06-28) — [archive](milestones/v1.0-ROADMAP.md)
- ✅ **v1.1 Concurrent Filing & Control** — Phases 5–9 (shipped 2026-07-02) — [archive](milestones/v1.1-ROADMAP.md)
- 📋 **v1.2 Issue-to-PR Worker** — planning baseline; requirements and phases not yet defined

## Next Milestone

### v1.2 Issue-to-PR Worker

Planning starts from the implementation already merged after the v1.1 shipped boundary:

- PR #10: normative worker product contract and threat model
- PR #11: worker CLI, strict configuration, routing, SQLite ledger, and doctor foundation
- PR #12: isolated workspace, diff inspection, validation, and draft-PR publisher pipeline
- PR #13: Claude Code provider adapter
- PRs #14–#15: private-repository Treehouse authentication and bounded/sandboxed doctor probes

These changes are **vNext groundwork**, not v1.1 deliverables. The next GSD milestone must turn
the remaining contract acceptance surface into fresh requirements and phases, including pickup and
reconciliation, app/worker integration, and the per-user worker lifecycle.

Start formal definition with `$gsd-new-milestone`.
