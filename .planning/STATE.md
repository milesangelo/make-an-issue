---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
current_phase: 04
current_phase_name: voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation
status: verifying
stopped_at: Completed 04-03-PLAN.md — AppState .filing, onRunIssueFiling seam, TTS, MenuView CLI Command field
last_updated: "2026-06-26T01:08:24.369Z"
last_activity: 2026-06-25
last_activity_desc: Phase 04 execution started
progress:
  total_phases: 4
  completed_phases: 4
  total_plans: 11
  completed_plans: 11
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-25)

**Core value:** Capture a repo-aware tracker issue (GitHub or Jira) by voice in seconds — spoken word to filed issue, end to end.
**Current focus:** Phase 04 — voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation

## Current Position

Phase: 04 (voice-ai-cli-drafts-files-issue-via-mcp-spoken-confirmation) — EXECUTING
Plan: 4 of 4
Status: Phase complete — ready for verification
Last activity: 2026-06-25 — Phase 04 execution started

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
- [Phase ?]: Phase 04-01: IssueParseError conforms to Equatable (TranscriberError style) for direct XCTest assertion
- [Phase ?]: Phase 04-01: IssueFilingConfig.mcpServerJSON stored as raw JSON string; no Foundation import needed in config type
- [Phase ?]: Phase 04-01: CLIRunner environment parameter placed between workingDirectory and timeout per plan interface spec
- [Phase ?]: Phase 04-02: ownerRepo optional in buildPrompt
- [Phase ?]: Phase 04-02: IssueParseError caught and rethrown as IssueFilingError in file() — callers see one error type
- [Phase ?]: Phase 04-03: onSpeak uses optional closure (nil=real TTS) — avoids self-reference in default param
- [Phase ?]: Phase 04-03: .finished is transient — beginTranscription success immediately calls beginFiling()
- [Phase ?]: Phase 04-04: parseFailed always means no issue URL found in CLI output (nothing filed) — old message implied false success
- [Phase ?]: Phase 04-04: IssueParseError.malformedOutput is declared but never thrown — dead enum case, left as-is for v1

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

Last session: 2026-06-26T01:08:09.890Z
Stopped at: Completed 04-03-PLAN.md — AppState .filing, onRunIssueFiling seam, TTS, MenuView CLI Command field
Resume file: None
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
