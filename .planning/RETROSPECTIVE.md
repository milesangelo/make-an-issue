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

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v1.0 | 4 | 15 | Mid-milestone realignment (`/gsd-explore`): bundled whisper + merged AI-CLI/MCP filing, `gh` retired |

### Cumulative Quality

| Milestone | Swift LOC | Files | Carried Tech Debt |
|-----------|-----------|-------|-------------------|
| v1.0 | ~3,660 | 23 | Orphaned CLI Command field; Nyquist docs incomplete on Phases 1–3 |

### Top Lessons (Verified Across Milestones)

1. Human-verify on real hardware catches what unit tests can't. *(v1.0 — re-confirm in future milestones)*
2. Realign scope early; don't ship-then-rework. *(v1.0 — re-confirm in future milestones)*
