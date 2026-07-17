# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — MVP

**Shipped:** 2026-06-28
**Phases:** 4 | **Plans:** 15 | **Tasks:** 19

### What Was Built
- Repo-bound native macOS menu-bar app launched/activated by a repo-local command (Phase 1).
- Push-to-talk global hotkey capturing 16 kHz mono WAV while held, hardware-verified (Phase 2).
- Zero-config transcription via a self-contained bundled `whisper-cli` + SHA-pinned model (Phase 3).
- Voice → `claude -p` drafts & files the issue through its own GitHub MCP, no app-held tokens, with
  the issue number parsed from stdout and spoken back via native TTS (Phase 4).

### What Worked
- **Human-verify checkpoints on real hardware** caught defects unit tests missed — Phase 2's blocking
  checkpoint surfaced a stuck capture state machine and a focus-only (non-global) hotkey, both fixed
  and re-verified before the phase closed.
- **Mid-milestone realignment via `/gsd-explore`** (2026-06-25) cleanly pivoted transcription to a
  bundled whisper model and merged Phases 4+5 (AI-CLI-files-via-MCP), retiring `gh` and all app-held
  tokens — a sharper, more defensible v1 than the original plan.
- **Shared, injectable seams** (`CLIRunner`, `onRunTranscription` / `onRunIssueFiling` closures) made
  the Process-spawning code reusable across transcription and filing and kept it unit-testable.
- **Spike-gating Phase 4** before committing the build de-risked the non-deterministic AI-CLI/MCP path.

### What Was Inefficient
- **Phase 3 was reopened and reworked mid-milestone** — the original user-ASR-CLI pipeline shipped and
  passed UAT, then was replaced by bundled whisper. Sound call, but it was rework that a slightly later
  realignment decision could have avoided up front.
- **Bundling a native binary was fiddly** — two UAT gaps (unpinned model SHA, missing `@rpath` dylibs)
  surfaced only when running the assembled `.app` outside the build tree, requiring an extra gap-closure
  plan (03-05) to rewrite `LC_RPATH` to `@loader_path` and bottom-up ad-hoc sign.
- **Two milestone audits** — the first (`gaps_found`) predated the Phase 3 rework + 04-05 gap closure and
  had to be superseded by a re-audit (`tech_debt`); auditing before the rework settled was premature.

### Patterns Established
- `CLIRunner` — one `Process`/`/bin/zsh -lc` wrapper (separate stdout/stderr, single-resume timeout)
  reused by every external-CLI call.
- Closure seams injected at `AppState.init` (default wires the real implementation) for test isolation.
- Parse ordering: a successfully-parsed `/issues/N` URL must win over the permission-denial gate
  (04-05 fix) — success signals beat absence-of-signal heuristics.
- Vendored native deps stay gitignored (`vendor/`, ~466 MB) and are fetched/SHA-verified by a script.

### Key Lessons
1. Verify hardware-dependent behavior on real hardware before closing a phase — global hotkeys and mic
   capture cannot be trusted from unit tests alone.
2. Realign early: a cheap `/gsd-explore` pass mid-milestone reshaped scope for the better, but doing it
   one phase sooner would have avoided shipping-then-reworking Phase 3.
3. Bundling native binaries on macOS needs rpath rewriting + (ad-hoc, then eventually Developer-ID)
   signing planned in from the start, and must be tested from the assembled `.app`, not the build tree.
4. Don't audit a milestone until in-flight rework and gap closures have settled — a premature audit just
   gets superseded.

### Cost Observations
- Model mix / session count: not instrumented this milestone (no reliable data captured).
- Notable: most plans were small (2–3 tasks); the costliest work was the Phase 3 bundled-whisper rework
  and the Phase 4 human-verify + gap-closure loop.

---

## Milestone: v1.1 — Concurrent Filing & Control

**Shipped:** 2026-07-02
**Phases:** 5 | **Plans:** 13 | **Tasks:** 32

### What Was Built

- Concurrent, independently retained filing jobs that no longer block the next recording.
- Full-process-tree per-job cancellation and quit teardown with scoped MCP-tempfile cleanup.
- AppKit status-item/popover architecture with right-click Settings/Quit and a recording-only red
  menu-bar indicator.
- Persisted drafting instructions whose tool scope and issue-output contract remain app-owned.
- A live jobs list with per-job Stop, terminal dismissal, safe issue links, and persistent
  recoverable error context.

### What Worked

- Empirical process-group tests de-risked cancellation before the implementation depended on it.
- Blocking human UAT caught a real quit-time tempfile race and proved status-item click routing,
  focus, recording feedback, and global-shortcut survival on macOS.
- The phase chain kept model, cancellation, shell, instructions, and jobs UI responsibilities
  separate while still producing an end-to-end control surface.
- Pure view-logic helpers made URL validation and terminal-row behavior testable without adding a
  rendered SwiftUI test dependency.

### What Was Inefficient

- Legacy `status: verified` frontmatter on Phases 6 and 7 later made current GSD readiness report
  those completed phases as unknown until closeout normalization.
- Summary one-liners were inconsistent enough that the generic milestone extractor produced noisy
  accomplishments and undercounted tasks; closeout required evidence-based manual correction.
- Phase 6's first manual quit gate found a cleanup race after automated tests had passed, requiring
  a targeted gap-closure loop.

### Patterns Established

- Keep capture state and long-running filing state in separate models.
- Treat dismissal and cancellation as distinct user actions.
- Keep editable prompt guidance separate from app-owned security and output constraints.
- For AppKit/SwiftUI interaction behavior, pair source-level wiring checks with explicit human UAT.

### Key Lessons

1. Persist completion metadata in the schema the current workflow actually reads; otherwise valid
   UAT evidence becomes invisible to readiness tooling.
2. Process-tree and AppKit lifecycle behavior need real runtime gates even when unit seams are
   strong.
3. Milestone archives must use the shipped commit boundary, not later repository state, when
   attributing requirements and accomplishments.
4. Later groundwork should remain visible in current-state docs without being back-attributed to
   the milestone being closed.

### Cost Observations

- Model mix / session count: not reliably instrumented.
- Notable: 13 small plans kept implementation reviewable; human UAT and the cancellation
  gap-closure loop carried most of the non-code coordination cost.

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v1.0 | 4 | 15 | Mid-milestone realignment (`/gsd-explore`): bundled whisper + merged AI-CLI/MCP filing, `gh` retired |
| v1.1 | 5 | 13 | Filing became concurrent and user-controllable; AppKit status shell and editable instructions added |

### Cumulative Quality

| Milestone | Swift LOC | Files | Carried Tech Debt |
|-----------|-----------|-------|-------------------|
| v1.0 | ~3,660 | 23 | Orphaned CLI Command field; Nyquist docs incomplete on Phases 1–3 |
| v1.1 | ~5,448 | 29 | Five non-blocking audit items; Nyquist partial on Phases 5–9 |

### Top Lessons (Verified Across Milestones)

1. Human verification on real hardware catches lifecycle and integration defects that source and
   unit checks cannot. *(v1.0, v1.1)*
2. Empirical gates should precede risky platform assumptions. *(v1.1; re-confirm in future milestones)*
3. Realign scope early; don't ship and then rework. *(v1.0; re-confirm in future milestones)*
