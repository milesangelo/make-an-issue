---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
current_phase: 4
current_phase_name: Repo Investigation → Issue Draft
status: ready
stopped_at: Phase 3 complete (UAT + security verified), ready to plan Phase 4
last_updated: "2026-06-25T19:54:03.063Z"
last_activity: 2026-06-25
last_activity_desc: Phase 03 complete, transitioned to Phase 4
progress:
  total_phases: 5
  completed_phases: 3
  total_plans: 7
  completed_plans: 7
  percent: 60
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-25)

**Core value:** Capture a repo-aware GitHub issue by voice in seconds — spoken word to filed issue, end to end.
**Current focus:** Phase 4 — Repo Investigation → Issue Draft

## Current Position

Phase: 4 — Repo Investigation → Issue Draft
Plan: Not started
Status: Ready to plan
Last activity: 2026-06-25 — Phase 03 complete, transitioned to Phase 4

Progress: [██████████] 100%

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

- Plan Phase 4 repo investigation → issue draft.

### Blockers/Concerns

- Tooling: Global GSD CLI (`~/.codex/gsd-core/bin/gsd-tools.cjs`) fails to load — `runtime-artifact-conversion.cjs` requires a missing `../../../package.json`. Bypassed by authoring artifacts directly from GSD templates. Re-run GSD commands only after the global install is fixed/updated.
- Phase 4: ASR CLI must be on the login-shell PATH by full path — `whisper.cpp` builds the binary as `whisper-cli` (not `whisper`) under `~/local_llm/whisper.cpp/build/bin`; the same PATH/binary-naming gotcha applies to the model CLI Phase 4 will spawn via CLIRunner.

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-06-25
Stopped at: Phase 3 complete (UAT 3/3 passed, security verified — threats_open: 0), ready to plan Phase 4
Resume file: None

## Performance Metrics

| Phase | Plan | Duration | Notes |
|-------|------|----------|-------|
| Phase 02 P01 | 115s | 2 tasks | 3 files |
| Phase 03 P01 | 101s | 2 tasks | 2 files |
| Phase 03 P02 | 295s | 3 tasks | 5 files |
