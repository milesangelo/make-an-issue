---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Concurrent Filing & Control
status: planning
last_updated: "2026-06-28T07:06:21.993Z"
last_activity: 2026-06-28
progress:
  total_phases: 0
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-28)

**Core value:** Capture a repo-aware tracker issue (GitHub or Jira) by voice in seconds — spoken word to filed issue, end to end.
**Current focus:** Planning next milestone (v1.0 MVP shipped 2026-06-28)

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-06-28 — Milestone v1.1 started

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
- [Phase ?]: Phase 04-01: IssueParseError conforms to Equatable (TranscriberError style) for direct XCTest assertion
- [Phase ?]: Phase 04-01: IssueFilingConfig.mcpServerJSON stored as raw JSON string; no Foundation import needed in config type
- [Phase ?]: Phase 04-01: CLIRunner environment parameter placed between workingDirectory and timeout per plan interface spec
- [Phase ?]: Phase 04-02: ownerRepo optional in buildPrompt
- [Phase ?]: Phase 04-02: IssueParseError caught and rethrown as IssueFilingError in file() — callers see one error type
- [Phase ?]: Phase 04-03: onSpeak uses optional closure (nil=real TTS) — avoids self-reference in default param
- [Phase ?]: Phase 04-03: .finished is transient — beginTranscription success immediately calls beginFiling()
- [Phase ?]: Phase 04-04: parseFailed always means no issue URL found in CLI output (nothing filed) — old message implied false success
- [Phase ?]: Phase 04-04: IssueParseError.malformedOutput is declared but never thrown — dead enum case, left as-is for v1
- [Phase ?]: Phase 03-03: MODEL_SHA256 initialized to unpinned sentinel — script computes and exits 1 on first download, forcing developer to pin the value before the model is usable
- [Phase ?]: Phase 03-03: vendor/ added to .gitignore so ~466 MB binary + model never enter git history (D-03)
- [Phase ?]: Phase 03-05: MODEL_SHA256 pinned to content digest c6138d6d...1e5d
- [Phase ?]: Phase 03-05: install_name_tool reads LC_RPATH dynamically via otool/awk (no hardcoded home path)

### Pending Todos

- (none — v1.0 todos resolved: Phase 3 bundled-whisper rework shipped; AI-CLI/MCP filing spike proven via `claude` + GitHub.)

### Blockers/Concerns

Open items carried into the next milestone:

- **Distribution gap:** bundled `whisper-cli` is only ad-hoc signed for local use. Developer-ID signing + hardened-runtime notarization is required before clean-machine distribution (deferred — see 03-CONTEXT.md D-04/D-05).
- **Provider breadth deferred:** `codex exec` non-interactive MCP writes are broken upstream (stdin-EOF auto-cancel); Atlassian/Jira zero-token non-interactive write may be infeasible. v1 proven leg = `claude -p` + GitHub remote MCP. Re-spike before promising non-Claude/Jira providers.
- **Tech debt (from v1.0 audit):** orphaned "CLI Command" UI field (FINDING-06); incomplete Nyquist/VALIDATION paperwork on Phases 1–3.
- AI-CLI output parsing is non-deterministic — instruct "issue URL on the last line" + regex extract; budget seconds-to-a-minute latency in the spoken-confirmation UX.

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-06-26T06:38:33.202Z
Stopped at: Phase 3 context reworked (bundled whisper)
Resume file: .planning/phases/03-local-transcription/03-CONTEXT.md
Decision record: .planning/notes/v1-realign-bundled-whisper-ai-cli-mcp.md

## Performance Metrics

| Phase | Plan | Duration | Notes |
|-------|------|----------|-------|
| Phase 02 P01 | 115s | 2 tasks | 3 files |
| Phase 03 P01 | 101s | 2 tasks | 2 files |
| Phase 03 P02 | 295s | 3 tasks | 5 files |
| Phase 04 P01 | 8m | 3 tasks | 6 files |
| Phase 04 P02 | 137s | 2 tasks | 2 files |
| Phase 04 P03 | 9m | 2 tasks | 3 files |
| Phase 04 P04 | 20min | 2 tasks | 2 files |
| Phase 03 P03 | 221 | - tasks | - files |
| Phase 03 P03 | 221 | 2 tasks | 3 files |
| Phase 03 P04 | 15m | 3 tasks | 5 files |
| Phase 03 P05 | 99s | 2 tasks | 2 files |
| Phase 04 P05 | 4m | 3 tasks | 2 files |

## Operator Next Steps

- Start the next milestone with /gsd-new-milestone
