---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
current_phase: 03
current_phase_name: Local Transcription (bundled-whisper rework)
status: ready
stopped_at: v1 realigned (bundled whisper + AI-CLI/MCP filing); next = Phase 3 rework, then spike before Phase 4
last_updated: "2026-06-25T20:30:00.000Z"
last_activity: 2026-06-25
last_activity_desc: Mid-milestone realignment via /gsd-explore (Phases 4+5 merged; gh retired)
progress:
  total_phases: 4
  completed_phases: 2
  total_plans: 13
  completed_plans: 7
  percent: 54
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-25)

**Core value:** Capture a repo-aware tracker issue (GitHub or Jira) by voice in seconds — spoken word to filed issue, end to end.
**Current focus:** Phase 3 rework — bundled-whisper transcription (then spike → merged Phase 4)

## Current Position

Phase: 3 (rework) — Local Transcription via bundled whisper
Plan: Not started (03-03 / 03-04)
Status: Ready to plan rework
Last activity: 2026-06-25 — v1 realigned via /gsd-explore (bundled whisper + AI-CLI/MCP filing)

Progress: [██████░░░░] 54% (7/13 plans)

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table. Recent decisions affecting current work:

- Init: Native Swift menu-bar app (`MenuBarExtra` + `LSUIElement`, non-sandboxed for v1).
- Init: Global push-to-talk shortcut (KeyboardShortcuts), not a wake phrase.
- Init: Local models via configured CLI commands; repo binding from launch cwd; auto issue creation via `gh`.
- Phase 1: Repo binding is filesystem-only for v1; it walks parent directories for `.git` markers and does not shell out.
- Phase 1: Launcher test override for the open command must be an absolute path.
- [Phase ?]: Closure seam over protocol for recorder injection in AppState — simpler for single-use test injection
- [Phase ?]: MainActor.assumeIsolated used in KeyboardShortcuts callbacks for Swift 6 strict concurrency compatibility
- Phase 03-02: onRunTranscription seam: (URL) async throws -> String — closure injected at AppState.init; default wires Transcriber.run
- Phase 03-02: captureState after successful transcription: .finished (user can start new recording from .finished)
- Phase 03-02: asrCommandKey = "asrCommand" — single static constant shared between AppState.UserDefaults and MenuView.@AppStorage

### Pending Todos

- Phase 3 rework (03-03/03-04): bundle + sign/notarize `whisper-cli` + model; rewire `Transcriber`; remove ASR Command field.
- Run `/gsd-spike` to prove non-interactive AI-CLI issue-filing via MCP (claude+GitHub first; codex + Jira) BEFORE planning the merged Phase 4.

### Blockers/Concerns

- Tooling: Global GSD CLI (`~/.codex/gsd-core/bin/gsd-tools.cjs`) fails to load — `runtime-artifact-conversion.cjs` requires a missing `../../../package.json`. Bypassed by authoring artifacts directly from GSD templates. Re-run GSD commands only after the global install is fixed/updated.
- ⚠️ Phase 4 spike-gated: `codex exec` non-interactive MCP writes are broken upstream (stdin-EOF auto-cancel); Atlassian/Jira zero-token non-interactive write may be infeasible (interactive OAuth). v1 proven leg = `claude -p` + GitHub remote MCP. Resolve via `/gsd-spike` before committing build.
- Phase 3 rework: bundled `whisper-cli` must be signed + hardened-runtime notarized or Gatekeeper blocks it on teammates' machines.
- AI-CLI output parsing is non-deterministic — instruct "issue URL on the last line" + regex extract; budget seconds-to-a-minute latency in the spoken-confirmation UX.

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-06-25
Stopped at: v1 realigned via /gsd-explore — bundled whisper + AI-CLI-files-via-MCP; Phases 4+5 merged, gh retired. Next = Phase 3 rework, then /gsd-spike before merged Phase 4.
Resume file: None
Decision record: .planning/notes/v1-realign-bundled-whisper-ai-cli-mcp.md

## Performance Metrics

| Phase | Plan | Duration | Notes |
|-------|------|----------|-------|
| Phase 02 P01 | 115s | 2 tasks | 3 files |
| Phase 03 P01 | 101s | 2 tasks | 2 files |
| Phase 03 P02 | 295s | 3 tasks | 5 files |
