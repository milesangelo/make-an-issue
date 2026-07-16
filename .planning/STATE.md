---
gsd_state_version: 1.0
milestone: v1.1
milestone_name: Concurrent Filing & Control
current_phase: 09
status: verifying
stopped_at: Completed 09-01-PLAN.md
last_updated: "2026-07-15T19:56:00-06:00"
last_activity: 2026-07-15
last_activity_desc: Completed quick task 260715-r4z make-an-issue-worker workspace and publisher pipeline
progress:
  total_phases: 5
  completed_phases: 5
  total_plans: 13
  completed_plans: 13
  percent: 100
current_phase_name: jobs-list-ui-per-job-stop-surfaced-errors
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-28)

**Core value:** Capture a repo-aware tracker issue (GitHub or Jira) by voice in seconds — spoken word to filed issue, end to end.
**Current focus:** Phase 09 — jobs-list-ui-per-job-stop-surfaced-errors

## Current Position

Phase: 09
Plan: Not started
Status: Phase complete — ready for verification
Last activity: 2026-07-15 — Completed quick task 260715-r4z make-an-issue-worker workspace and publisher pipeline

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
- [Phase ?]: AppKit shell via NSStatusItem replaces MenuBarExtra; indicator driven by layer backgroundColor (not contentTintColor); Settings window self-owned NSWindowController; assign-popUp-clear for right-click menu
- [Phase 08]: instructionsKey = "instructions" added to AppState, mirroring the removed cliCommandKey template (D-05) — Follows existing @AppStorage cross-reference doc-comment convention; single source of truth for Plan 03's SettingsView binding
- [Phase 08]: enforcedTrailer lives on IssueFilingRunner (not IssueFilingConfig) — provider-agnostic prose, mirrors shellEscape's standalone pure static helper pattern — buildPrompt/file()/AppState default closure now assemble the prompt so the app-owned URL trailer + file-it directive always come after user-editable instructions, and AppState reads UserDefaults fresh per invocation (not cached) to preserve concurrent-filing isolation (D-02/D-03/D-06/D-08/SETTINGS-04)
- [Phase 08]: Phase 8: Explicit window height (460) added to Settings TabView after human-verify showed width-only frame collapsed content height to ~zero
- [Phase ?]: Phase 09-01: dismiss(jobID:)/clearFinished() are terminal-only jobs[] mutations — never call task?.cancel(); dismissal is not cancellation (D-05/D-06)
- [Phase ?]: Phase 09-01: JobRowStyle is a plain non-@MainActor namespace enum so icon/color/openableIssueURL statics are unit-testable without a rendered-view harness
- [Phase ?]: Phase 09-01: openableIssueURL admits only https-scheme URLs (case-insensitive) — defense-in-depth guard on AI-CLI-stdout-derived issue URLs ahead of Plan 09-02's NSWorkspace.shared.open
- [Phase 09]: Phase 09-02: JobsSection ScrollView fixed at 180pt max-height per 09-RESEARCH Open Question 1 -- confirmed correct via UAT, no adjustment needed
- [Phase 09]: Phase 09-02: Clear-all only renders when a non-.filing job exists in appState.jobs, avoiding a no-op control when only in-flight jobs are present
- [Phase 09]: Phase 09-02: No automated rendered-view tests added (no ViewInspector/SnapshotTesting in project) -- JobsSection/JobRow verified via human-verify UAT checkpoint, approved by operator

### Pending Todos

- (none — v1.0 todos resolved: Phase 3 bundled-whisper rework shipped; AI-CLI/MCP filing spike proven via `claude` + GitHub.)

### Blockers/Concerns

Open items carried into the v1.1 milestone:

- ~~**Cancellation correctness (Phase 6):**~~ RESOLVED in Phase 6 — process-group SIGTERM→2s grace→SIGKILL on cancel and quit paths; `make-an-issue-mcp-*.json` swept on quit (synchronous sweep fix, commit 30fd152). UAT verified, threats SECURED (06-SECURITY.md).
- ~~**KeyboardShortcuts under NSPopover/NSMenu (Phase 7):**~~ RESOLVED in Phase 7 — the `MenuBarExtra` `.onDisappear` end-tracking workaround was removed; UAT Test 6 (2026-07-01) confirmed push-to-talk fires across popover/menu open-close cycles and while the popover is open (A4 closed). Threats SECURED (07-SECURITY.md).
- **Editable-prompt parse safety (Phase 8):** keep the editable field instructions-only; the enforced contract (scoped `--allowedTools`, `method=create`, "Issue URL on last line") is appended by `buildPrompt` and the CLI flags live in `assembleCommand`. Harden `IssueResultParser` prose fallback to match the **last** URL/line, not the first occurrence anywhere, or user edits produce false "created #N".
- **Distribution gap (carried):** the release `.app` (nested whisper Mach-O files, then the sealed outer bundle) is signed by `build-app.sh` with `CODESIGN_IDENTITY` (ad-hoc `-` by default) and strict-verified via `scripts/verify-app-signing.sh` — but an ad-hoc signature is not Gatekeeper-approved. Developer-ID signing + hardened-runtime notarization required before clean-machine distribution (deferred — DIST-01; see 03-CONTEXT.md D-04/D-05).
- **Provider breadth deferred (carried):** `codex exec` non-interactive MCP writes broken upstream; Atlassian/Jira zero-token non-interactive write may be infeasible. v1 proven leg = `claude -p` + GitHub remote MCP. Re-spike before promising non-Claude/Jira providers (PROVIDER-01).
- **Migration cost (Phase 5):** the jobs-model refactor intentionally rewrites serial-filing AppStateTests (`testFilingEntersFilingState`, `testPushToTalkDuringFilingIsIgnored` — re-press during filing is now *allowed*, the feature; `testStartRecordingAfterFilingReturnsToIdle`; `.filing` assertions in `testSuccessfulTranscriptionStoresText`).

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260715-k1m | Release app signing | 2026-07-15 | 8dcfb3d | [260715-k1m-release-app-signing](./quick/260715-k1m-release-app-signing/) |
| 260715-k29 | Author make-an-issue-worker product contract and threat model design docs | 2026-07-15 | b05dbc3 | [260715-k29-author-make-an-issue-worker-product-cont](./quick/260715-k29-author-make-an-issue-worker-product-cont/) |
| 260715-ptv | Implement make-an-issue-worker CLI foundation | 2026-07-15 | 45c50d7 | [260715-ptv-implement-make-an-issue-worker-cli-skele](./quick/260715-ptv-implement-make-an-issue-worker-cli-skele/) |
| 260715-r4z | Implement make-an-issue-worker workspace and builtin publisher pipeline | 2026-07-15 | c2dbf29 | [260715-r4z-implement-the-make-an-issue-worker-works](./quick/260715-r4z-implement-the-make-an-issue-worker-works/) |

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-07-02T13:32:41.174Z
Stopped at: Completed 09-01-PLAN.md
Resume file: None
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
| Phase 07 P01 | 4 minutes | 3 tasks | 4 files |
| Phase 07 P02 | 2m | 1 tasks | 0 files |
| Phase 08 P01 | 8min | 2 tasks | 2 files |
| Phase 08 P02 | 7min | 2 tasks | 5 files |
| Phase 08 P03 | 12min | 2 tasks | 1 files |
| Phase Phase 09 PP01 | 8min | 3 tasks | 4 files |
| Phase 09 P02 | 15min | 2 tasks | 1 files |

## Operator Next Steps

- Plan Phase 8 (Editable System Prompt + FINDING-06 Cleanup) with /gsd-plan-phase 8
- Phase 9 follow-up captured: add an in-flight "Filing issue…" indicator (no UI feedback during background investigation today) — see 06-UAT.md follow-up
