---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Concurrent Filing & Control
current_phase: 7
current_phase_name: AppKit Status-Item UI + Settings Window Shell
status: ready_to_plan
stopped_at: Phase 7 context gathered
last_updated: "2026-06-30T18:15:46.573Z"
last_activity: 2026-06-30
last_activity_desc: Phase 06 verified & complete, transitioned to Phase 7
progress:
  total_phases: 5
  completed_phases: 2
  total_plans: 6
  completed_plans: 6
  percent: 40
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-28)

**Core value:** Capture a repo-aware tracker issue (GitHub or Jira) by voice in seconds — spoken word to filed issue, end to end.
**Current focus:** Phase 07 — AppKit Status-Item UI + Settings Window Shell

## Current Position

Phase: 7 — AppKit Status-Item UI + Settings Window Shell
Plan: Not started
Status: Ready to plan
Last activity: 2026-06-30 — Phase 06 verified & complete, transitioned to Phase 7

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
- [Phase ?]: jobs model
- [Phase 06]: A1 confirmed: Foundation.Process spawns /bin/zsh children as their own process-group leaders — kill(-pgid) approach is safe
- [Phase 06]: A2 confirmed: spawned child group is distinct from app group — group-directed signal stays in child tree
- [Phase 06]: Negative-PID reap confirmed: kill(-pid, SIGTERM) reaps the spawned process group on macOS within 3s
- [Phase ?]: Phase 06-03: cancel(jobID:) only calls task?.cancel() — .cancelled state transition owned by CancellationError catch arm after process dead
- [Phase ?]: Phase 06-03: CancellationError catch arm before IssueFilingError arm — CancellationError is not an IssueFilingError; generic catch would swallow it as failure
- [Phase ?]: Phase 06-03: onRunIssueFiling seam gains @escaping @Sendable (pid_t)->Void 3rd param — @escaping required on inner closure type
- [Phase ?]: Phase 06-04: sweepMCPTempFiles is static and parameterised for unit testability
- [Phase ?]: Phase 06-04: cancelAll() before Task.sleep for correct SIGTERM-first D-04 ordering
- [Phase ?]: Phase 06-04: defer NSApp.reply in teardown Task guarantees no Quit hang (SC-4)

### Pending Todos

- (none — v1.0 todos resolved: Phase 3 bundled-whisper rework shipped; AI-CLI/MCP filing spike proven via `claude` + GitHub.)

### Blockers/Concerns

Open items carried into the v1.1 milestone:

- ~~**Cancellation correctness (Phase 6):**~~ RESOLVED in Phase 6 — process-group SIGTERM→2s grace→SIGKILL on cancel and quit paths; `make-an-issue-mcp-*.json` swept on quit (synchronous sweep fix, commit 30fd152). UAT verified, threats SECURED (06-SECURITY.md).
- **KeyboardShortcuts under NSPopover/NSMenu (Phase 7):** the `MenuBarExtra` `.onDisappear` hotkey workaround may fire spuriously or be unneeded once on `NSStatusItem` — re-validate empirically, do not blindly carry over.
- **Editable-prompt parse safety (Phase 8):** keep the editable field instructions-only; the enforced contract (scoped `--allowedTools`, `method=create`, "Issue URL on last line") is appended by `buildPrompt` and the CLI flags live in `assembleCommand`. Harden `IssueResultParser` prose fallback to match the **last** URL/line, not the first occurrence anywhere, or user edits produce false "created #N".
- **Distribution gap (carried):** bundled `whisper-cli` is only ad-hoc signed for local use. Developer-ID signing + hardened-runtime notarization required before clean-machine distribution (deferred — DIST-01; see 03-CONTEXT.md D-04/D-05).
- **Provider breadth deferred (carried):** `codex exec` non-interactive MCP writes broken upstream; Atlassian/Jira zero-token non-interactive write may be infeasible. v1 proven leg = `claude -p` + GitHub remote MCP. Re-spike before promising non-Claude/Jira providers (PROVIDER-01).
- **Migration cost (Phase 5):** the jobs-model refactor intentionally rewrites serial-filing AppStateTests (`testFilingEntersFilingState`, `testPushToTalkDuringFilingIsIgnored` — re-press during filing is now *allowed*, the feature; `testStartRecordingAfterFilingReturnsToIdle`; `.filing` assertions in `testSuccessfulTranscriptionStoresText`).

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-06-30T18:15:46.569Z
Stopped at: Phase 7 context gathered
Resume file: .planning/phases/07-appkit-status-item-ui-settings-window-shell/07-CONTEXT.md
Decision record: .planning/research/SUMMARY.md (v1.1 research)

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
| Phase 05 P01 | 549s | 3 tasks | 5 files |
| Phase 05 P02 | 845 | 3 tasks | 1 files |
| Phase 06 P01 | 225s | 2 tasks | 2 files |
| Phase 06 P02 | 660s | 3 tasks | 4 files |
| Phase 06 P03 | 1080 | 3 tasks | 2 files |
| Phase 06 P04 | 10m | 2 tasks | 2 files |

## Operator Next Steps

- Plan Phase 7 (AppKit Status-Item UI + Settings Window Shell) with /gsd-plan-phase 7
- Phase 9 follow-up captured: add an in-flight "Filing issue…" indicator (no UI feedback during background investigation today) — see 06-UAT.md follow-up
